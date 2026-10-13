-- =====================================================================
--  ALFA BROTHER: TE VAMOS A COBRAR
--  Script para Supabase. Pégalo completo en SQL Editor → Run.
--  Se puede volver a ejecutar sin perder datos (crea lo que falte y
--  actualiza las funciones).
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
--  TABLAS
-- ---------------------------------------------------------------------

-- Estado general del juego (una sola fila)
create table if not exists public.config (
  id            int primary key default 1 check (id = 1),
  semana        int  not null default 0,
  fase          text not null default 'registro'
                check (fase in ('registro','prueba','votacion','decision','gala')),
  prueba        text check (prueba in ('trivia','memoria','adeudo')),
  lider_id      uuid,
  eliminado_id  uuid,
  empatados     uuid[] not null default '{}',
  gala_revelada boolean not null default false,
  cupo          int  not null default 16 check (cupo between 2 and 100),
  actualizado   timestamptz not null default now()
);
insert into public.config (id) values (1) on conflict do nothing;

-- Habitantes y espectadores
create table if not exists public.jugadores (
  id               uuid primary key default gen_random_uuid(),
  nombre           text not null check (char_length(nombre) between 2 and 30),
  pin_hash         text not null,
  foto             text,
  rol              text not null default 'jugador' check (rol in ('jugador','espectador')),
  estado           text not null default 'activo'  check (estado in ('activo','eliminado')),
  semana_eliminado int,
  fallos           int  not null default 0,
  bloqueado_hasta  timestamptz,
  creado           timestamptz not null default now()
);
create unique index if not exists jugadores_nombre_unico on public.jugadores (lower(btrim(nombre)));

-- Sesiones de los celulares
create table if not exists public.sesiones (
  token      uuid primary key default gen_random_uuid(),
  jugador_id uuid not null references public.jugadores(id) on delete cascade,
  creado     timestamptz not null default now()
);

-- Preguntas de trivia de la oficina
create table if not exists public.trivia (
  id        bigint generated always as identity primary key,
  pregunta  text not null check (char_length(pregunta) between 3 and 200),
  opciones  text[] not null check (array_length(opciones, 1) = 4),
  correcta  int not null check (correcta between 0 and 3),
  activa    boolean not null default false,
  creado    timestamptz not null default now()
);

-- Un intento de prueba por habitante por semana
create table if not exists public.intentos (
  id         bigint generated always as identity primary key,
  semana     int  not null,
  jugador_id uuid not null references public.jugadores(id) on delete cascade,
  prueba     text not null,
  puntaje    int,
  iniciado   timestamptz not null default now(),
  terminado  timestamptz,
  unique (semana, jugador_id)
);

-- Votos de eliminación (3, 2 y 1 puntos)
create table if not exists public.votos (
  id         bigint generated always as identity primary key,
  semana     int  not null,
  votante_id uuid not null references public.jugadores(id) on delete cascade,
  votado_id  uuid not null references public.jugadores(id) on delete cascade,
  puntos     int  not null check (puntos in (1,2,3)),
  motivo     text check (char_length(motivo) <= 200),
  es_publico boolean not null default false,
  oculto     boolean not null default false,
  creado     timestamptz not null default now(),
  unique (semana, votante_id, puntos),
  unique (semana, votante_id, votado_id)
);

-- Resultado congelado de cada gala
create table if not exists public.historial (
  semana     int primary key,
  resultados jsonb not null,
  creado     timestamptz not null default now()
);

-- Quién es administrador (se llena a mano, ver la guía)
create table if not exists public.admins (
  user_id uuid primary key
);

-- v2: sala de espera
alter table public.config    add column if not exists inicio_at timestamptz;
alter table public.jugadores add column if not exists frase text check (char_length(frase) <= 60);

-- v3: agenda automática de cada semana
alter table public.config add column if not exists ag_semana     int;
alter table public.config add column if not exists ag_prueba     text;
alter table public.config add column if not exists ag_prueba_ini timestamptz;
alter table public.config add column if not exists ag_prueba_fin timestamptz;
alter table public.config add column if not exists ag_voto_ini   timestamptz;
alter table public.config add column if not exists ag_voto_fin   timestamptz;
alter table public.config add column if not exists ag_gala       timestamptz;
alter table public.config add column if not exists ag_repetir    boolean not null default true;
-- nueva fase 'espera': la prueba ya cerró pero la votación todavía no abre
alter table public.config drop constraint if exists config_fase_check;
alter table public.config add constraint config_fase_check
  check (fase in ('registro','prueba','espera','votacion','decision','gala'));

-- v3: chismes que escribe la producción para el ojo de la tele
create table if not exists public.chismes (
  id     bigint generated always as identity primary key,
  texto  text not null check (char_length(texto) between 3 and 160),
  activo boolean not null default true,
  creado timestamptz not null default now()
);

-- v4: chismes que mandan los jugadores; quedan pendientes hasta que la producción los revise.
-- No se guarda quién los escribió.
alter table public.chismes add column if not exists pendiente boolean not null default false;

-- Predicción secreta: quién gana y quién sale primero
create table if not exists public.predicciones (
  jugador_id  uuid primary key references public.jugadores(id) on delete cascade,
  ganador_id  uuid references public.jugadores(id) on delete set null,
  primero_id  uuid references public.jugadores(id) on delete set null,
  creado      timestamptz not null default now()
);

-- ---------------------------------------------------------------------
--  SEGURIDAD: nadie lee las tablas directamente, salvo el admin.
--  Los celulares solo usan las funciones de abajo.
-- ---------------------------------------------------------------------

create or replace function public.es_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

do $$
declare t text;
begin
  foreach t in array array['config','jugadores','sesiones','trivia','intentos','votos','historial','admins','predicciones','chismes'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists admin_todo on public.%I', t);
    execute format('create policy admin_todo on public.%I for all to authenticated using (public.es_admin()) with check (public.es_admin())', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
--  FUNCIONES INTERNAS
-- ---------------------------------------------------------------------

create or replace function public._yo(p_token uuid)
returns public.jugadores language plpgsql stable security definer set search_path = public as $$
declare j public.jugadores;
begin
  select jg.* into j from public.sesiones s join public.jugadores jg on jg.id = s.jugador_id
   where s.token = p_token;
  if not found then raise exception 'SESION_INVALIDA'; end if;
  return j;
end $$;

create or replace function public._solo_admin()
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not public.es_admin() then raise exception 'NO_AUTORIZADO'; end if;
end $$;

-- Tabla de resultados de una semana (puntos oficiales y del público)
create or replace function public._resultados(p_semana int)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  c public.config;
  r jsonb;
begin
  select * into c from public.config where id = 1;
  select coalesce(jsonb_agg(x order by x.puntos desc, x.nombre), '[]'::jsonb) into r from (
    select j.id, j.nombre,
           coalesce(sum(v.puntos) filter (where not v.es_publico), 0)::int as puntos,
           coalesce(sum(v.puntos) filter (where v.es_publico), 0)::int     as publico,
           count(v.id) filter (where not v.es_publico)::int                as votos,
           (j.id = c.lider_id and p_semana = c.semana)                     as lider,
           coalesce(
             (select jsonb_agg(jsonb_build_object('t', m.motivo, 'p', m.es_publico) order by random())
                from public.votos m
               where m.semana = p_semana and m.votado_id = j.id and not m.oculto
                 and m.motivo is not null and btrim(m.motivo) <> ''),
             '[]'::jsonb) as motivos
      from public.jugadores j
      left join public.votos v on v.votado_id = j.id and v.semana = p_semana
     where j.rol = 'jugador'
       and (j.estado = 'activo' or j.semana_eliminado >= p_semana)
     group by j.id, j.nombre
  ) x;
  return r;
end $$;

revoke all on function public._yo(uuid)          from public, anon, authenticated;
revoke all on function public._solo_admin()      from public, anon, authenticated;
revoke all on function public._resultados(int)   from public, anon, authenticated;

-- ---------------------------------------------------------------------
--  FUNCIONES PARA LOS JUGADORES
-- ---------------------------------------------------------------------

-- Información pública para la pantalla de registro
create or replace function public.info_publica()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'cupo', c.cupo,
    'habitantes', (select count(*) from public.jugadores where rol = 'jugador'),
    'semana', c.semana,
    'fase', c.fase)
  from public.config c where c.id = 1;
$$;

drop function if exists public.registrar(text, text, text);
drop function if exists public.registrar(text, text, text, text);
create or replace function public.registrar(p_nombre text, p_pin text, p_foto text default null, p_frase text default null, p_publico boolean default false)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  c public.config;
  v_nombre text := regexp_replace(btrim(coalesce(p_nombre, '')), '\s+', ' ', 'g');
  v_frase text := nullif(left(btrim(coalesce(p_frase, '')), 60), '');
  v_rol text;
  v_id uuid;
  v_token uuid;
begin
  if char_length(v_nombre) < 2 or char_length(v_nombre) > 30 then raise exception 'NOMBRE_INVALIDO'; end if;
  if coalesce(p_pin, '') !~ '^[0-9]{4}$' then raise exception 'PIN_INVALIDO'; end if;
  if p_foto is not null and (char_length(p_foto) > 250000 or p_foto !~ '^data:image/(jpeg|png|webp);base64,') then
    raise exception 'FOTO_INVALIDA';
  end if;

  select * into c from public.config where id = 1 for update;   -- evita que dos se registren en el lugar 16 a la vez

  if exists (select 1 from public.jugadores where lower(btrim(nombre)) = lower(v_nombre)) then
    raise exception 'NOMBRE_OCUPADO';
  end if;

  -- quien elige "solo ver" entra como público aunque haya lugar
  if not coalesce(p_publico, false) and c.semana = 0 and (select count(*) from public.jugadores where rol = 'jugador') < c.cupo then
    v_rol := 'jugador';
  else
    v_rol := 'espectador';
  end if;

  insert into public.jugadores (nombre, pin_hash, foto, rol, frase)
  values (v_nombre, crypt(p_pin, gen_salt('bf')), p_foto, v_rol, v_frase)
  returning id into v_id;

  insert into public.sesiones (jugador_id) values (v_id) returning token into v_token;
  return jsonb_build_object('token', v_token, 'rol', v_rol);
end $$;

create or replace function public.entrar(p_nombre text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  j public.jugadores;
  v_token uuid;
begin
  select * into j from public.jugadores
   where lower(btrim(nombre)) = lower(regexp_replace(btrim(coalesce(p_nombre, '')), '\s+', ' ', 'g'));
  if not found then raise exception 'NO_EXISTE'; end if;
  if j.bloqueado_hasta is not null and j.bloqueado_hasta > now() then raise exception 'BLOQUEADO'; end if;

  if j.pin_hash <> crypt(coalesce(p_pin, ''), j.pin_hash) then
    update public.jugadores
       set fallos = fallos + 1,
           bloqueado_hasta = case when fallos + 1 >= 5 then now() + interval '10 minutes' else null end
     where id = j.id;
    return jsonb_build_object('error', 'PIN_INCORRECTO');
  end if;

  update public.jugadores set fallos = 0, bloqueado_hasta = null where id = j.id;
  insert into public.sesiones (jugador_id) values (j.id) returning token into v_token;
  return jsonb_build_object('token', v_token);
end $$;

create or replace function public.salir(p_token uuid)
returns void language sql security definer set search_path = public as $$
  delete from public.sesiones where token = p_token;
$$;

-- Todo lo que la pantalla principal necesita (sin fotos, para que sea ligero)
create or replace function public.estado(p_token uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  yo public.jugadores;
  c public.config;
  v_activos int;
  v_fin boolean;
begin
  yo := public._yo(p_token);
  perform public._avanzar_agenda();
  select * into c from public.config where id = 1;
  select count(*) into v_activos from public.jugadores where rol = 'jugador' and estado = 'activo';
  v_fin := c.semana > 0 and v_activos <= 1 and c.gala_revelada;

  return jsonb_build_object(
    'yo', jsonb_build_object('id', yo.id, 'nombre', yo.nombre, 'rol', yo.rol, 'estado', yo.estado, 'frase', yo.frase),
    'mi_prediccion', (select jsonb_build_object('ganador_id', p.ganador_id, 'primero_id', p.primero_id)
        from public.predicciones p where p.jugador_id = yo.id),
    'predicciones', case when v_fin then (select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.jugador_id, 'ganador_id', p.ganador_id, 'primero_id', p.primero_id)), '[]'::jsonb)
        from public.predicciones p) end,
    'primer_eliminado', (select (h.resultados->>'eliminado_id') from public.historial h where h.semana = 1),
    'juego', jsonb_build_object(
      'inicio_at', c.inicio_at, 'fin', v_fin,
      'agenda', case when c.ag_semana in (c.semana, c.semana + 1) then jsonb_build_object(
        'semana', c.ag_semana, 'prueba', c.ag_prueba, 'prueba_ini', c.ag_prueba_ini, 'prueba_fin', c.ag_prueba_fin,
        'voto_ini', c.ag_voto_ini, 'voto_fin', c.ag_voto_fin, 'gala', c.ag_gala) end,
      'semana', c.semana, 'fase', c.fase, 'prueba', c.prueba, 'cupo', c.cupo,
      'lider_id', c.lider_id,
      'gala_revelada', c.gala_revelada,
      'empatados', case when c.fase = 'decision' then to_jsonb(c.empatados) else '[]'::jsonb end,
      'eliminado_id', case when c.gala_revelada then c.eliminado_id end,
      'activos', v_activos),
    'jugadores', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', j.id, 'nombre', j.nombre, 'rol', j.rol, 'estado', j.estado, 'frase', j.frase,
        'semana_eliminado', j.semana_eliminado, 'foto', j.foto is not null)
        order by j.rol, j.estado, j.nombre), '[]'::jsonb) from public.jugadores j),
    'fotos_firma', (select count(*) filter (where foto is not null) || '-' || count(*) from public.jugadores),
    'mis_votos', (select coalesce(jsonb_agg(jsonb_build_object('id', v.votado_id, 'puntos', v.puntos, 'motivo', v.motivo)
        order by v.puntos desc), '[]'::jsonb)
        from public.votos v where v.semana = c.semana and v.votante_id = yo.id),
    'mi_intento', (select jsonb_build_object('puntaje', i.puntaje, 'terminado', i.terminado is not null)
        from public.intentos i where i.semana = c.semana and i.jugador_id = yo.id),
    'galas', (select coalesce(jsonb_agg(h.semana order by h.semana desc), '[]'::jsonb) from public.historial h)
  );
end $$;

create or replace function public.fotos(p_token uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._yo(p_token);
  return (select coalesce(jsonb_object_agg(id, foto), '{}'::jsonb) from public.jugadores where foto is not null);
end $$;

create or replace function public.cambiar_foto(p_token uuid, p_foto text)
returns void language plpgsql security definer set search_path = public as $$
declare yo public.jugadores;
begin
  yo := public._yo(p_token);
  if p_foto is not null and (char_length(p_foto) > 250000 or p_foto !~ '^data:image/(jpeg|png|webp);base64,') then
    raise exception 'FOTO_INVALIDA';
  end if;
  update public.jugadores set foto = p_foto where id = yo.id;
end $$;

create or replace function public.cambiar_frase(p_token uuid, p_frase text)
returns void language plpgsql security definer set search_path = public as $$
declare yo public.jugadores;
begin
  yo := public._yo(p_token);
  update public.jugadores set frase = nullif(left(btrim(coalesce(p_frase, '')), 60), '') where id = yo.id;
end $$;

-- Predicción secreta (solo antes de que empiece la semana 1)
create or replace function public.predecir(p_token uuid, p_ganador uuid, p_primero uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  yo public.jugadores;
  c public.config;
begin
  yo := public._yo(p_token);
  select * into c from public.config where id = 1;
  if c.semana <> 0 then raise exception 'PREDICCIONES_CERRADAS'; end if;
  if (p_ganador is not null and not exists (select 1 from public.jugadores where id = p_ganador and rol = 'jugador'))
     or (p_primero is not null and not exists (select 1 from public.jugadores where id = p_primero and rol = 'jugador')) then
    raise exception 'PREDICCION_INVALIDA';
  end if;
  insert into public.predicciones (jugador_id, ganador_id, primero_id) values (yo.id, p_ganador, p_primero)
  on conflict (jugador_id) do update set ganador_id = excluded.ganador_id, primero_id = excluded.primero_id, creado = now();
end $$;

-- Gala congelada de una semana (solo después de la revelación)
create or replace function public.gala(p_token uuid, p_semana int)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._yo(p_token);
  return (select resultados from public.historial where semana = p_semana);
end $$;

-- Empieza la prueba (una sola oportunidad por semana)
create or replace function public.iniciar_prueba(p_token uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  yo public.jugadores;
  c public.config;
  v_n int;
begin
  yo := public._yo(p_token);
  select * into c from public.config where id = 1;
  if c.fase <> 'prueba' then raise exception 'PRUEBA_CERRADA'; end if;
  if yo.rol <> 'jugador' or yo.estado <> 'activo' then raise exception 'NO_PARTICIPA'; end if;

  insert into public.intentos (semana, jugador_id, prueba) values (c.semana, yo.id, c.prueba)
  on conflict (semana, jugador_id) do nothing;
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'YA_JUGASTE'; end if;

  if c.prueba = 'trivia' then
    return jsonb_build_object('prueba', 'trivia', 'preguntas',
      (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'pregunta', t.pregunta, 'opciones', to_jsonb(t.opciones))
                       order by random()), '[]'::jsonb)
         from public.trivia t where t.activa));
  end if;
  return jsonb_build_object('prueba', c.prueba);
end $$;

-- Puntaje de memoria / adeudo
create or replace function public.enviar_puntaje(p_token uuid, p_puntaje int)
returns int language plpgsql security definer set search_path = public as $$
declare
  yo public.jugadores;
  c public.config;
  v int := least(greatest(coalesce(p_puntaje, 0), 0), 20000);
begin
  yo := public._yo(p_token);
  select * into c from public.config where id = 1;
  if c.fase <> 'prueba' or c.prueba = 'trivia' then raise exception 'PRUEBA_CERRADA'; end if;
  update public.intentos set puntaje = v, terminado = now()
   where semana = c.semana and jugador_id = yo.id and terminado is null;
  if not found then raise exception 'SIN_INTENTO'; end if;
  return v;
end $$;

-- Respuestas de trivia: [{id, opcion, ms}] — se califica aquí, en el servidor
create or replace function public.enviar_trivia(p_token uuid, p_respuestas jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  yo public.jugadores;
  c public.config;
  v_puntaje int := 0;
  v_bien int := 0;
  v_total int;
  r jsonb;
  t public.trivia;
begin
  yo := public._yo(p_token);
  select * into c from public.config where id = 1;
  if c.fase <> 'prueba' or c.prueba <> 'trivia' then raise exception 'PRUEBA_CERRADA'; end if;
  select count(*) into v_total from public.trivia where activa;

  for r in select distinct on ((e->>'id')::bigint) e from jsonb_array_elements(coalesce(p_respuestas, '[]'::jsonb)) e loop
    select * into t from public.trivia where id = (r->>'id')::bigint and activa;
    if found and (r->>'opcion')::int = t.correcta then
      v_bien := v_bien + 1;
      v_puntaje := v_puntaje + 100
        + greatest(0, 50 - least(greatest(coalesce((r->>'ms')::int, 12000), 0), 12000) / 240);
    end if;
  end loop;

  update public.intentos set puntaje = v_puntaje, terminado = now()
   where semana = c.semana and jugador_id = yo.id and terminado is null;
  if not found then raise exception 'SIN_INTENTO'; end if;
  return jsonb_build_object('puntaje', v_puntaje, 'bien', v_bien, 'total', v_total);
end $$;

-- Voto: [{id, puntos, motivo}] con 3, 2 y 1 puntos (o menos si quedan pocos habitantes)
create or replace function public.votar(p_token uuid, p_votos jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  yo public.jugadores;
  c public.config;
  v_req int;
  v_n int;
  e jsonb;
begin
  yo := public._yo(p_token);
  select * into c from public.config where id = 1;
  if c.fase <> 'votacion' then raise exception 'VOTACION_CERRADA'; end if;

  select least(3, count(*)) into v_req from public.jugadores
   where rol = 'jugador' and estado = 'activo' and id <> yo.id;

  v_n := jsonb_array_length(coalesce(p_votos, '[]'::jsonb));
  if v_n <> v_req then raise exception 'VOTOS_INCOMPLETOS'; end if;

  if (select count(distinct (x->>'id')) from jsonb_array_elements(p_votos) x) <> v_n
     or (select count(distinct (x->>'puntos')::int) from jsonb_array_elements(p_votos) x
          where (x->>'puntos')::int between 4 - v_req and 3) <> v_n then
    raise exception 'VOTOS_INVALIDOS';
  end if;

  for e in select * from jsonb_array_elements(p_votos) loop
    if not exists (select 1 from public.jugadores
                    where id = (e->>'id')::uuid and rol = 'jugador' and estado = 'activo' and id <> yo.id) then
      raise exception 'VOTOS_INVALIDOS';
    end if;
    if char_length(coalesce(e->>'motivo', '')) > 200 then raise exception 'MOTIVO_LARGO'; end if;
  end loop;

  delete from public.votos where semana = c.semana and votante_id = yo.id;
  insert into public.votos (semana, votante_id, votado_id, puntos, motivo, es_publico)
  select c.semana, yo.id, (x->>'id')::uuid, (x->>'puntos')::int,
         nullif(btrim(coalesce(x->>'motivo', '')), ''), yo.rol = 'espectador'
    from jsonb_array_elements(p_votos) x;
end $$;

-- El líder rompe el empate
create or replace function public.lider_decide(p_token uuid, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  yo public.jugadores;
  c public.config;
begin
  yo := public._yo(p_token);
  select * into c from public.config where id = 1 for update;
  if c.fase <> 'decision' or c.lider_id is distinct from yo.id then raise exception 'NO_AUTORIZADO'; end if;
  if not (p_id = any (c.empatados)) then raise exception 'NO_EMPATADO'; end if;
  update public.config set eliminado_id = p_id, fase = 'gala', gala_revelada = false, actualizado = now() where id = 1;
end $$;

-- ---------------------------------------------------------------------
--  FUNCIONES DEL ADMINISTRADOR
-- ---------------------------------------------------------------------

create or replace function public._iniciar_semana(p_prueba text)
returns void language plpgsql security definer set search_path = public as $$
declare c public.config;
begin
  select * into c from public.config where id = 1 for update;
  if not (c.fase = 'registro' or (c.fase = 'gala' and c.gala_revelada)) then raise exception 'FASE_INCORRECTA'; end if;
  if p_prueba not in ('trivia','memoria','adeudo') then raise exception 'PRUEBA_INVALIDA'; end if;
  if p_prueba = 'trivia' and not exists (select 1 from public.trivia where activa) then raise exception 'SIN_TRIVIAS'; end if;
  -- con un solo habitante en la casa ya hay ganador: no se abre otra semana
  if c.semana > 0 and (select count(*) from public.jugadores where rol = 'jugador' and estado = 'activo') <= 1 then
    raise exception 'JUEGO_TERMINADO';
  end if;
  update public.config
     set semana = c.semana + 1, fase = 'prueba', prueba = p_prueba, lider_id = null, eliminado_id = null,
         empatados = '{}', gala_revelada = false, actualizado = now()
   where id = 1;
end $$;

-- Cierra la prueba. Sin p_lider elige al mejor puntaje (empate: quien terminó primero).
create or replace function public._cerrar_prueba(p_lider uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  c public.config;
  v_lider uuid := p_lider;
begin
  select * into c from public.config where id = 1 for update;
  if c.fase <> 'prueba' then raise exception 'FASE_INCORRECTA'; end if;
  if v_lider is null then
    select i.jugador_id into v_lider
      from public.intentos i join public.jugadores j on j.id = i.jugador_id
     where i.semana = c.semana and i.puntaje is not null and j.estado = 'activo' and j.rol = 'jugador'
     order by i.puntaje desc, i.terminado asc
     limit 1;
  end if;
  update public.config
     set lider_id = v_lider,
         fase = case when c.ag_semana = c.semana and c.ag_voto_ini > now() then 'espera' else 'votacion' end,
         actualizado = now()
   where id = 1;
  return v_lider;
end $$;

create or replace function public.admin_set_lider(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._solo_admin();
  update public.config set lider_id = p_id, actualizado = now() where id = 1;
end $$;

-- Cierra la votación: el que más puntos tiene sale. El líder se salva.
-- Si hay empate, decide el líder (o el admin si no hay líder).
create or replace function public._cerrar_votacion()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c public.config;
  res jsonb;
  v_max int;
  v_emp uuid[];
begin
  select * into c from public.config where id = 1 for update;
  if c.fase <> 'votacion' then raise exception 'FASE_INCORRECTA'; end if;

  res := public._resultados(c.semana);
  select max((x->>'puntos')::int) into v_max
    from jsonb_array_elements(res) x where (x->>'id')::uuid is distinct from c.lider_id;
  select array_agg((x->>'id')::uuid) into v_emp
    from jsonb_array_elements(res) x
   where (x->>'id')::uuid is distinct from c.lider_id and (x->>'puntos')::int = v_max;

  if v_emp is null then raise exception 'SIN_CANDIDATOS'; end if;

  if array_length(v_emp, 1) = 1 then
    update public.config set eliminado_id = v_emp[1], empatados = '{}', fase = 'gala', gala_revelada = false, actualizado = now() where id = 1;
  else
    update public.config set eliminado_id = null, empatados = v_emp, fase = 'decision', actualizado = now() where id = 1;
  end if;
  return jsonb_build_object('empate', array_length(v_emp, 1) > 1, 'candidatos', to_jsonb(v_emp));
end $$;

-- El admin decide un empate (cuando no hay líder o el líder no responde)
create or replace function public.admin_decidir(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare c public.config;
begin
  perform public._solo_admin();
  select * into c from public.config where id = 1 for update;
  if c.fase <> 'decision' or not (p_id = any (c.empatados)) then raise exception 'NO_EMPATADO'; end if;
  update public.config set eliminado_id = p_id, fase = 'gala', gala_revelada = false, actualizado = now() where id = 1;
end $$;

-- Lanza la gala en todos los celulares
create or replace function public._revelar()
returns void language plpgsql security definer set search_path = public as $$
declare
  c public.config;
  res jsonb;
  v_max_lider int;
  v_max_otros int;
begin
  select * into c from public.config where id = 1 for update;
  if c.fase <> 'gala' or c.eliminado_id is null or c.gala_revelada then raise exception 'FASE_INCORRECTA'; end if;

  res := public._resultados(c.semana);
  select max((x->>'puntos')::int) filter (where (x->>'id')::uuid = c.lider_id),
         max((x->>'puntos')::int) filter (where (x->>'id')::uuid is distinct from c.lider_id)
    into v_max_lider, v_max_otros
    from jsonb_array_elements(res) x;

  insert into public.historial (semana, resultados) values (c.semana, jsonb_build_object(
    'semana', c.semana,
    'eliminado_id', c.eliminado_id,
    'eliminado', (select nombre from public.jugadores where id = c.eliminado_id),
    'lider_id', c.lider_id,
    'lider', (select nombre from public.jugadores where id = c.lider_id),
    'lider_salvado', coalesce(v_max_lider > 0 and v_max_lider >= v_max_otros, false),
    'desempate', cardinality(c.empatados) > 1,
    'tabla', res))
  on conflict (semana) do update set resultados = excluded.resultados, creado = now();

  update public.jugadores set estado = 'eliminado', semana_eliminado = c.semana where id = c.eliminado_id;
  update public.config set gala_revelada = true, actualizado = now() where id = 1;
  if (select count(*) from public.jugadores where rol = 'jugador' and estado = 'activo') <= 1 then
    -- fue la gran final: se apaga la agenda para que no empiece otra semana
    update public.config set ag_semana = null, ag_prueba_ini = null, ag_prueba_fin = null,
           ag_voto_ini = null, ag_voto_fin = null, ag_gala = null where id = 1;
  elsif c.ag_repetir and c.ag_semana = c.semana then
    update public.config
       set ag_semana = ag_semana + 1,
           ag_prueba_ini = ag_prueba_ini + interval '7 days', ag_prueba_fin = ag_prueba_fin + interval '7 days',
           ag_voto_ini = ag_voto_ini + interval '7 days', ag_voto_fin = ag_voto_fin + interval '7 days',
           ag_gala = ag_gala + interval '7 days'
     where id = 1;
  end if;
end $$;

-- Botones del panel: mismas acciones, solo para el admin
create or replace function public.admin_iniciar_semana(p_prueba text)
returns void language plpgsql security definer set search_path = public as $$
begin perform public._solo_admin(); perform public._iniciar_semana(p_prueba); end $$;

create or replace function public.admin_cerrar_prueba(p_lider uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
begin perform public._solo_admin(); return public._cerrar_prueba(p_lider); end $$;

create or replace function public.admin_cerrar_votacion()
returns jsonb language plpgsql security definer set search_path = public as $$
begin perform public._solo_admin(); return public._cerrar_votacion(); end $$;

create or replace function public.admin_revelar()
returns void language plpgsql security definer set search_path = public as $$
begin perform public._solo_admin(); perform public._revelar(); end $$;

-- Guarda la agenda de una semana (fechas en null = se hace a mano)
create or replace function public.admin_set_agenda(p jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._solo_admin();
  if p is null then
    update public.config set ag_semana = null, ag_prueba = null, ag_prueba_ini = null, ag_prueba_fin = null,
           ag_voto_ini = null, ag_voto_fin = null, ag_gala = null, actualizado = now() where id = 1;
    return;
  end if;
  if coalesce(p->>'prueba', 'memoria') not in ('trivia','memoria','adeudo') then raise exception 'PRUEBA_INVALIDA'; end if;
  update public.config
     set ag_semana     = (p->>'semana')::int,
         ag_prueba     = coalesce(p->>'prueba', 'memoria'),
         ag_prueba_ini = nullif(p->>'prueba_ini', '')::timestamptz,
         ag_prueba_fin = nullif(p->>'prueba_fin', '')::timestamptz,
         ag_voto_ini   = nullif(p->>'voto_ini', '')::timestamptz,
         ag_voto_fin   = nullif(p->>'voto_fin', '')::timestamptz,
         ag_gala       = nullif(p->>'gala', '')::timestamptz,
         ag_repetir    = coalesce((p->>'repetir')::boolean, true),
         actualizado   = now()
   where id = 1;
end $$;

-- El panel también empuja la agenda al abrirse
create or replace function public.admin_tick()
returns void language plpgsql security definer set search_path = public as $$
begin perform public._solo_admin(); perform public._avanzar_agenda(); end $$;

-- El reloj del juego: revisa la agenda y avanza las fases que ya tocan.
-- Se ejecuta cada vez que un celular pide el estado (cada ~7 segundos).
create or replace function public._avanzar_agenda()
returns void language plpgsql security definer set search_path = public as $$
declare
  c public.config;
  vueltas int := 0;
begin
  select * into c from public.config where id = 1;
  -- revisión rápida sin bloquear: ¿hay algo vencido?
  if not coalesce(c.ag_semana is not null and (
       (c.ag_semana = c.semana + 1 and (c.fase = 'registro' or (c.fase = 'gala' and c.gala_revelada)) and c.ag_prueba_ini <= now())
    or (c.ag_semana = c.semana and (
           (c.fase = 'prueba'   and c.ag_prueba_fin <= now())
        or (c.fase = 'espera'   and coalesce(c.ag_voto_ini, now()) <= now())
        or (c.fase = 'votacion' and c.ag_voto_fin <= now())
        or (c.fase in ('decision', 'gala') and not c.gala_revelada and c.ag_gala <= now())))), false) then
    return;
  end if;

  perform 1 from public.config where id = 1 for update;     -- un solo celular a la vez
  loop
    vueltas := vueltas + 1;
    exit when vueltas > 6;
    select * into c from public.config where id = 1;
    begin
      if c.ag_semana = c.semana + 1 and (c.fase = 'registro' or (c.fase = 'gala' and c.gala_revelada))
         and c.ag_prueba_ini <= now() then
        begin
          perform public._iniciar_semana(coalesce(c.ag_prueba, 'memoria'));
        exception when others then
          perform public._iniciar_semana('adeudo');            -- p. ej. trivia sin preguntas activas
        end;
      elsif c.ag_semana is distinct from c.semana then
        exit;
      elsif c.fase = 'prueba' and c.ag_prueba_fin <= now() then
        perform public._cerrar_prueba(null);
      elsif c.fase = 'espera' and coalesce(c.ag_voto_ini, now()) <= now() then
        update public.config set fase = 'votacion', actualizado = now() where id = 1;
      elsif c.fase = 'votacion' and c.ag_voto_fin <= now() then
        perform public._cerrar_votacion();
      elsif c.fase = 'decision' and c.ag_gala <= now() then
        -- el líder no decidió a tiempo: el programa elige al azar entre los empatados
        update public.config
           set eliminado_id = c.empatados[1 + floor(random() * cardinality(c.empatados))::int],
               fase = 'gala', gala_revelada = false, actualizado = now()
         where id = 1;
      elsif c.fase = 'gala' and not c.gala_revelada and c.eliminado_id is not null and c.ag_gala <= now() then
        perform public._revelar();
      else
        exit;
      end if;
    exception when others then
      exit;
    end;
  end loop;
end $$;

-- El ojo de la tele: pistas reales (sin decir nombres) + chismes de la producción
create or replace function public.ojo(p_token uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  yo public.jugadores;
  c public.config;
  v_mios int; v_votaron int; v_total int; v_publico int; v_lider_voto boolean;
  pistas jsonb := '[]'::jsonb;
begin
  yo := public._yo(p_token);
  select * into c from public.config where id = 1;
  if c.fase = 'votacion' then
    select count(distinct votante_id) into v_mios from public.votos
     where semana = c.semana and votado_id = yo.id and not es_publico;
    select count(distinct votante_id) into v_votaron from public.votos where semana = c.semana and not es_publico;
    select count(*) into v_total from public.jugadores where rol = 'jugador';
    select count(distinct votante_id) into v_publico from public.votos where semana = c.semana and es_publico;
    v_lider_voto := exists (select 1 from public.votos where semana = c.semana and votante_id = c.lider_id);
    if yo.rol = 'jugador' and yo.estado = 'activo' then
      if v_mios >= 4 then pistas := pistas || to_jsonb('Más de tres personas ya votaron por ti. Yo que tú, me cuidaba. 👀'::text);
      elsif v_mios >= 1 then pistas := pistas || to_jsonb('Tú no lo sabes, pero alguien ya votó por ti.'::text);
      elsif v_votaron >= 3 then pistas := pistas || to_jsonb('Nadie ha votado por ti… todavía.'::text);
      end if;
    end if;
    if v_votaron > 0 then pistas := pistas || to_jsonb(format('Ya pasaron %s habitantes por el confesionario esta semana.', v_votaron)); end if;
    if v_total - v_votaron > 0 then pistas := pistas || to_jsonb(format('Todavía faltan %s por votar. ¿Qué estarán esperando?', v_total - v_votaron)); end if;
    if v_publico > 0 then pistas := pistas || to_jsonb('El público también está votando… y tiene opiniones.'::text); end if;
    if c.lider_id is not null and c.lider_id <> yo.id then
      pistas := pistas || to_jsonb(case when v_lider_voto then 'El líder ya entró al confesionario.' else 'El líder todavía no vota. ¿Estará dudando?' end);
    end if;
  end if;
  return jsonb_build_object(
    'pistas', pistas,
    'propios', (select coalesce(jsonb_agg(texto), '[]'::jsonb) from public.chismes where activo));
end $$;

-- Un jugador le cuenta un chisme al ojo (anónimo, queda pendiente de revisión)
create or replace function public.proponer_chisme(p_token uuid, p_texto text)
returns void language plpgsql security definer set search_path = public as $$
declare v text := regexp_replace(btrim(coalesce(p_texto, '')), '\s+', ' ', 'g');
begin
  perform public._yo(p_token);                       -- solo gente registrada
  if char_length(v) < 3 or char_length(v) > 160 then raise exception 'CHISME_INVALIDO'; end if;
  if (select count(*) from public.chismes where pendiente) >= 200 then raise exception 'BUZON_LLENO'; end if;
  insert into public.chismes (texto, activo, pendiente) values (v, false, true);
end $$;

-- Cuenta regresiva de la sala de espera (null la quita)
create or replace function public.admin_set_inicio(p_inicio timestamptz)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._solo_admin();
  update public.config set inicio_at = p_inicio, actualizado = now() where id = 1;
end $$;

-- Salida de emergencia: mover la fase a mano
create or replace function public.admin_fase(p_fase text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._solo_admin();
  if p_fase not in ('prueba','espera','votacion') then raise exception 'FASE_INVALIDA'; end if;
  update public.config set fase = p_fase, eliminado_id = null, empatados = '{}', gala_revelada = false, actualizado = now() where id = 1;
end $$;

create or replace function public.admin_reset_pin(p_id uuid, p_pin text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public._solo_admin();
  if coalesce(p_pin, '') !~ '^[0-9]{4}$' then raise exception 'PIN_INVALIDO'; end if;
  update public.jugadores set pin_hash = crypt(p_pin, gen_salt('bf')), fallos = 0, bloqueado_hasta = null where id = p_id;
  delete from public.sesiones where jugador_id = p_id;
end $$;

-- Deshace una eliminación
create or replace function public.admin_reactivar(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._solo_admin();
  update public.jugadores set estado = 'activo', semana_eliminado = null where id = p_id;
end $$;

-- Borra votos, pruebas y galas; deja a los jugadores registrados
create or replace function public.admin_reiniciar_juego()
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._solo_admin();
  delete from public.votos where true;
  delete from public.intentos where true;
  delete from public.historial where true;
  delete from public.predicciones where true;
  update public.jugadores set estado = 'activo', semana_eliminado = null where true;
  update public.config set semana = 0, fase = 'registro', prueba = null, lider_id = null, eliminado_id = null,
         empatados = '{}', gala_revelada = false, actualizado = now() where id = 1;
end $$;

-- Las funciones internas no se pueden llamar directo desde el celular
revoke all on function public._iniciar_semana(text)  from public, anon, authenticated;
revoke all on function public._cerrar_prueba(uuid)   from public, anon, authenticated;
revoke all on function public._cerrar_votacion()     from public, anon, authenticated;
revoke all on function public._revelar()             from public, anon, authenticated;
revoke all on function public._avanzar_agenda()      from public, anon, authenticated;

-- Que Supabase reconozca de inmediato las funciones nuevas
notify pgrst, 'reload schema';
