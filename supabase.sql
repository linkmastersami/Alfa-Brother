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

-- v5: gran final (con 3 o menos en la casa no hay prueba ni líder; se vota por los lugares)
alter table public.config add column if not exists es_final   boolean not null default false;
alter table public.config add column if not exists terminado  boolean not null default false;
alter table public.config add column if not exists aviso_voto int;   -- semana en que ya se mandó el recordatorio de votar

-- v6: avisos al celular (web push)
create table if not exists public.push_subs (
  endpoint   text primary key,
  sub        jsonb not null,
  jugador_id uuid not null references public.jugadores(id) on delete cascade,
  creado     timestamptz not null default now()
);
-- Llaves de los avisos: las crea sola la función "avisos" la primera vez que se usa
create table if not exists public.push_ajustes (
  id            int primary key default 1 check (id = 1),
  vapid_publica text,
  vapid_privada text,
  clave         text,
  funcion_url   text
);

-- v7: Billetes Alfa, apuestas, encuesta del día, misiones secretas, récords y tienda
alter table public.jugadores add column if not exists billetes    int    not null default 2000;
alter table public.jugadores alter column billetes set default 2000;
alter table public.jugadores add column if not exists ultimo_bono date;
alter table public.jugadores add column if not exists estilo      jsonb  not null default '{}'::jsonb;
alter table public.jugadores add column if not exists compras     text[] not null default '{}';

-- Cada entrada o salida de billetes
create table if not exists public.movimientos (
  id         bigint generated always as identity primary key,
  jugador_id uuid not null references public.jugadores(id) on delete cascade,
  monto      int  not null,
  concepto   text not null,
  creado     timestamptz not null default now()
);
create index if not exists movimientos_jugador on public.movimientos (jugador_id, creado desc);

-- v11: saldo inicial de $2,000. A quien ya estaba registrado se le suman $1,000 una sola vez.
alter table public.config add column if not exists inicio_doble boolean not null default false;
do $$ begin
  if not (select inicio_doble from public.config where id = 1) then
    insert into public.movimientos (jugador_id, monto, concepto)
      select id, 1000, 'Ajuste: ahora todos empiezan con $2,000' from public.jugadores;
    update public.jugadores set billetes = billetes + 1000 where true;
    update public.config set inicio_doble = true where id = 1;
  end if;
end $$;

-- Apuestas con pozo compartido: líder y eliminado de la semana, y encuestas
create table if not exists public.apuestas (
  id         bigint generated always as identity primary key,
  tipo       text   not null check (tipo in ('lider','eliminado','encuesta')),
  ref        bigint not null,                 -- semana o id de la encuesta
  jugador_id uuid   not null references public.jugadores(id) on delete cascade,
  opcion     text   not null,                 -- id del jugador o número de opción
  monto      int    not null check (monto > 0),
  pago       int,                             -- null = todavía no se decide
  creado     timestamptz not null default now(),
  unique (tipo, ref, jugador_id)
);

-- Encuesta del día (la producción la programa)
create table if not exists public.encuestas (
  id        bigint generated always as identity primary key,
  pregunta  text  not null check (char_length(pregunta) between 3 and 140),
  opciones  jsonb not null,                   -- [{"t": "texto", "id": jugador o null}]
  abre      timestamptz not null default now(),
  cierra    timestamptz not null,
  resultado jsonb,                            -- {"conteo": [..], "ganadores": [..]}
  avisada   boolean not null default false,
  liquidada boolean not null default false,
  creado    timestamptz not null default now(),
  check (cierra > abre)
);
create table if not exists public.encuesta_votos (
  encuesta_id bigint not null references public.encuestas(id) on delete cascade,
  jugador_id  uuid   not null references public.jugadores(id) on delete cascade,
  opcion      int    not null,
  primary key (encuesta_id, jugador_id)
);

-- Misiones secretas: el banco de ideas ({nombre} = la persona objetivo) y las repartidas
create table if not exists public.misiones_banco (
  id     bigint generated always as identity primary key,
  texto  text not null unique check (char_length(texto) between 5 and 160),
  activa boolean not null default true,
  creado timestamptz not null default now()
);
create table if not exists public.misiones (
  id          bigint generated always as identity primary key,
  semana      int  not null,
  jugador_id  uuid not null references public.jugadores(id) on delete cascade,
  objetivo_id uuid not null references public.jugadores(id) on delete cascade,
  texto       text not null,
  codigo      text not null unique,
  cumplida    timestamptz,
  unique (semana, jugador_id)
);

-- v9: 5 misiones por semana (n = 1..5)
alter table public.misiones add column if not exists n int not null default 1;
alter table public.misiones drop constraint if exists misiones_semana_jugador_id_key;
create unique index if not exists misiones_semana_jugador_n on public.misiones (semana, jugador_id, n);
-- v14: sin código QR. Quien la cumplió toca "Ya la cumplí" (pedida) y la otra persona confirma o dice que es falso
alter table public.misiones add column if not exists pedida timestamptz;

-- Récords de las prácticas
create table if not exists public.practicas (
  jugador_id    uuid not null references public.jugadores(id) on delete cascade,
  juego         text not null check (juego in ('memoria','adeudo')),
  mejor         int  not null default 0,
  partidas      int  not null default 0,
  ultimo_premio date,
  ultimo_record date,
  primary key (jugador_id, juego)
);

-- v16: Monster Crazy también guarda récord (y paga como las prácticas)
alter table public.practicas drop constraint if exists practicas_juego_check;
alter table public.practicas add constraint practicas_juego_check check (juego in ('memoria','adeudo','monster','monster2'));   -- v17: Monster Crazy 2.0

-- Tienda para personalizar el monito
create table if not exists public.tienda (
  id     text primary key,
  tipo   text not null check (tipo in ('sombrero','lentes','color','mano')),
  nombre text not null,
  icono  text not null,                       -- emoji o color
  precio int  not null check (precio >= 0),
  orden  int  not null default 0
);

-- v8: celulares de la producción (reciben avisos de lo que hay que revisar)
create table if not exists public.push_produccion (
  endpoint text primary key,
  creado   timestamptz not null default now()
);

-- v12: avisos de la producción guardados (botón de notificaciones en la casa)
create table if not exists public.anuncios (
  id     bigint generated always as identity primary key,
  titulo text not null check (char_length(titulo) between 2 and 60),
  cuerpo text check (char_length(cuerpo) <= 160),
  creado timestamptz not null default now()
);

-- v13: chat de la casa (solo habitantes)
create table if not exists public.chat (
  id         bigint generated always as identity primary key,
  jugador_id uuid not null references public.jugadores(id) on delete cascade,
  texto      text not null check (char_length(texto) between 1 and 300),
  menciones  uuid[] not null default '{}',
  creado     timestamptz not null default now()
);

-- v19: El Noticierazo (resumen del día anterior). Bitácora de lo que pasa y notas de la producción.
create table if not exists public.sucesos (
  id         bigint generated always as identity primary key,
  tipo       text not null,
  jugador_id uuid references public.jugadores(id) on delete cascade,
  dato       jsonb not null default '{}'::jsonb,
  creado     timestamptz not null default now()
);
create table if not exists public.noticiero_notas (
  dia    date primary key,
  texto  text not null check (char_length(texto) between 1 and 400),
  creado timestamptz not null default now()
);
-- v21: la nota puede ser un guion: qué dice cada locutor, en orden ([{"q":"e"|"a","t":"..."}])
alter table public.noticiero_notas add column if not exists guion jsonb;
alter table public.noticiero_notas drop constraint if exists noticiero_notas_texto_check;
alter table public.noticiero_notas add constraint noticiero_notas_texto_check check (char_length(texto) between 1 and 4000);

-- v22: el reportero del Noticierazo: los habitantes le cuentan noticias y le llegan a la producción
create table if not exists public.reportajes (
  id         bigint generated always as identity primary key,
  jugador_id uuid not null references public.jugadores(id) on delete cascade,
  texto      text not null check (char_length(texto) between 3 and 500),
  usado      boolean not null default false,
  creado     timestamptz not null default now()
);

-- v24: duelos entre habitantes (2 jugadores, con apuesta: el que gana se lleva lo de los dos)
create table if not exists public.duelos (
  id       bigint generated always as identity primary key,
  juego    text not null check (juego in ('ppt', 'globo', 'calculo', 'camino')),
  reta     uuid not null references public.jugadores(id) on delete cascade,     -- quien desafía
  retado   uuid not null references public.jugadores(id) on delete cascade,
  apuesta  int  not null default 0 check (apuesta between 0 and 5000),
  estado   text not null default 'pendiente' check (estado in ('pendiente', 'rechazado', 'caducado', 'cancelado', 'jugando', 'terminado')),
  datos    jsonb not null default '{}'::jsonb,     -- operaciones, el camino, las manos de cada ronda…
  res_a    jsonb,                                  -- resultado de quien retó (cálculo)
  res_b    jsonb,                                  -- resultado del retado
  ganador  uuid references public.jugadores(id) on delete set null,
  creado   timestamptz not null default now(),
  inicio   timestamptz,
  fin      timestamptz
);
create index if not exists duelos_activos on public.duelos (estado) where estado in ('pendiente', 'jugando');

-- v25: cada que cambia una foto (la cambie el habitante o la producción) los celulares la vuelven a bajar
alter table public.jugadores add column if not exists foto_v int not null default 0;
create or replace function public._foto_cambio() returns trigger language plpgsql as $$
begin
  if new.foto is distinct from old.foto then new.foto_v := old.foto_v + 1; end if;
  return new;
end $$;
drop trigger if exists jugadores_foto_v on public.jugadores;
create trigger jugadores_foto_v before update of foto on public.jugadores for each row execute function public._foto_cambio();

-- v27: en la pasarela, si hay empate, Ricky Reflector le llama al líder y tiene 50 segundos para decidir
alter table public.config add column if not exists llamada_ini timestamptz;
alter table public.config add column if not exists llamada_hasta timestamptz;

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
  foreach t in array array['config','jugadores','sesiones','trivia','intentos','votos','historial','admins','predicciones','chismes','push_subs','push_ajustes',
                                'movimientos','apuestas','encuestas','encuesta_votos','misiones_banco','misiones','practicas','tienda','push_produccion','anuncios','chat','sucesos','noticiero_notas','reportajes','duelos'] loop
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
  perform public._avisar_produccion('🙋 Nuevo registro', format('%s entró como %s.', v_nombre, case when v_rol = 'jugador' then 'habitante' else 'público' end));
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
  v_bono int;
begin
  yo := public._yo(p_token);
  perform public._avanzar_agenda();
  perform public._recordatorios();
  perform public._encuestas();
  -- bono por entrar cada día
  if yo.ultimo_bono is distinct from public._hoy() then
    update public.jugadores set ultimo_bono = public._hoy() where id = yo.id and ultimo_bono is distinct from public._hoy();
    if found then perform public._mover(yo.id, 200, 'Bono por entrar hoy'); v_bono := 200; end if;
  end if;
  select * into c from public.config where id = 1;
  select count(*) into v_activos from public.jugadores where rol = 'jugador' and estado = 'activo';
  v_fin := c.terminado or (c.semana > 0 and v_activos <= 1 and c.gala_revelada);

  return jsonb_build_object(
    'yo', jsonb_build_object('id', yo.id, 'nombre', yo.nombre, 'rol', yo.rol, 'estado', yo.estado, 'frase', yo.frase),
    'mi_prediccion', (select jsonb_build_object('ganador_id', p.ganador_id, 'primero_id', p.primero_id)
        from public.predicciones p where p.jugador_id = yo.id),
    'predicciones', case when v_fin then (select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.jugador_id, 'ganador_id', p.ganador_id, 'primero_id', p.primero_id)), '[]'::jsonb)
        from public.predicciones p) end,
    'primer_eliminado', (select (h.resultados->>'eliminado_id') from public.historial h where h.semana = 1),
    'podio', case when v_fin then (select h.resultados->'podio' from public.historial h where h.semana = c.semana) end,
    'juego', jsonb_build_object(
      'inicio_at', c.inicio_at, 'fin', v_fin, 'es_final', c.es_final,
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
        'semana_eliminado', j.semana_eliminado, 'foto', j.foto is not null,
        'estilo', (select jsonb_object_agg(t.tipo, t.icono) from public.tienda t
                    where t.id in (select value from jsonb_each_text(j.estilo))))
        order by j.rol, j.estado, j.nombre), '[]'::jsonb) from public.jugadores j),
    'fotos_firma', (select count(*) filter (where foto is not null) || '-' || count(*) || '-' || coalesce(sum(foto_v), 0) from public.jugadores),
    'mis_votos', (select coalesce(jsonb_agg(jsonb_build_object('id', v.votado_id, 'puntos', v.puntos, 'motivo', v.motivo)
        order by v.puntos desc), '[]'::jsonb)
        from public.votos v where v.semana = c.semana and v.votante_id = yo.id),
    'mi_intento', (select jsonb_build_object('puntaje', i.puntaje, 'terminado', i.terminado is not null)
        from public.intentos i where i.semana = c.semana and i.jugador_id = yo.id),
    -- misiones que cumplí la semana pasada: cuentan la mitad para el líder de esta semana
    'misiones_previas', (select count(*) from public.misiones m
        where m.semana = c.semana - 1 and m.jugador_id = yo.id and m.cumplida is not null),
    'galas', (select coalesce(jsonb_agg(h.semana order by h.semana desc), '[]'::jsonb) from public.historial h)
  ) || public._economia(yo.id, v_bono) || public._duelos_estado(yo.id);
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
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare c public.config; r jsonb;
begin
  perform public._yo(p_token);
  perform public._empate_vencido();
  select resultados into r from public.historial where semana = p_semana;
  if r is null then return null; end if;
  select * into c from public.config where id = 1;
  return r || jsonb_build_object('ahora', now(),
    'llamada_hasta', case when c.semana = p_semana and coalesce((r->>'empate_pendiente')::boolean, false) then c.llamada_hasta end);
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
  v_ya boolean;
  v_votaron int;
  v_total int;
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

  v_ya := exists (select 1 from public.votos where semana = c.semana and votante_id = yo.id);
  delete from public.votos where semana = c.semana and votante_id = yo.id;
  insert into public.votos (semana, votante_id, votado_id, puntos, motivo, es_publico)
  select c.semana, yo.id, (x->>'id')::uuid, (x->>'puntos')::int,
         nullif(btrim(coalesce(x->>'motivo', '')), ''), yo.rol = 'espectador'
    from jsonb_array_elements(p_votos) x;
  -- aviso a la producción (solo la primera vez que vota, no cuando cambia su voto)
  if not v_ya then
    select count(distinct votante_id) into v_votaron from public.votos where semana = c.semana and not es_publico;
    select count(*) into v_total from public.jugadores where rol = 'jugador';
    if yo.rol = 'espectador' then
      perform public._avisar_produccion('🗳️ Votó el público', format('%s ya votó (su voto no cuenta).', yo.nombre));
    elsif v_votaron >= v_total then
      perform public._avisar_produccion('✅ Ya votaron todos', format('%s fue el último. Ya puedes cerrar la votación.', yo.nombre));
    else
      perform public._avisar_produccion('🗳️ Nuevo voto', format('%s ya votó. Van %s de %s.', yo.nombre, v_votaron, v_total));
    end if;
  end if;
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
  if c.lider_id is distinct from yo.id then raise exception 'NO_AUTORIZADO'; end if;
  if not (p_id = any (c.empatados)) then raise exception 'NO_EMPATADO'; end if;
  if c.fase = 'gala' and c.gala_revelada and c.eliminado_id is null then          -- v27: la llamada de la pasarela
    if c.llamada_hasta is not null and now() > c.llamada_hasta + interval '4 seconds' then raise exception 'LLAMADA_VENCIDA'; end if;
    perform public._resolver_empate(p_id, 'lider');
    return;
  end if;
  if c.fase <> 'decision' then raise exception 'NO_AUTORIZADO'; end if;
  update public.config set eliminado_id = p_id, fase = 'gala', gala_revelada = false, actualizado = now() where id = 1;
end $$;

-- ---------------------------------------------------------------------
--  FUNCIONES DEL ADMINISTRADOR
-- ---------------------------------------------------------------------

create or replace function public._iniciar_semana(p_prueba text)
returns void language plpgsql security definer set search_path = public as $$
declare
  c public.config;
  v_act int;
  v_final boolean;
begin
  perform public._resolver_empate(null, 'azar');            -- v27: un empate de la pasarela que nadie decidió
  select * into c from public.config where id = 1 for update;
  if not (c.fase = 'registro' or (c.fase = 'gala' and c.gala_revelada)) then raise exception 'FASE_INCORRECTA'; end if;
  select count(*) into v_act from public.jugadores where rol = 'jugador' and estado = 'activo';
  -- ya hubo gran final (o solo queda uno): no se abre otra semana
  if c.terminado or (c.semana > 0 and v_act <= 1) then raise exception 'JUEGO_TERMINADO'; end if;
  -- con 3 o menos en la casa es la gran final: sin prueba ni líder, se vota directo
  v_final := v_act between 2 and 3;
  if not v_final then
    if p_prueba not in ('trivia','memoria','adeudo') then raise exception 'PRUEBA_INVALIDA'; end if;
    if p_prueba = 'trivia' and not exists (select 1 from public.trivia where activa) then raise exception 'SIN_TRIVIAS'; end if;
  end if;
  update public.config
     set semana = c.semana + 1,
         fase = case when not v_final then 'prueba'
                     when c.ag_semana = c.semana + 1 and c.ag_voto_ini > now() then 'espera'
                     else 'votacion' end,
         prueba = case when v_final then null else p_prueba end,
         es_final = v_final, lider_id = null, eliminado_id = null,
         empatados = '{}', gala_revelada = false, actualizado = now()
   where id = 1;
  insert into public.sucesos (tipo, dato) values ('semana', jsonb_build_object('semana', c.semana + 1, 'prueba', case when v_final then null else p_prueba end, 'final', v_final));
  -- misiones secretas de la semana nueva
  begin perform public._repartir_misiones(c.semana + 1, false);
  exception when others then null; end;
end $$;

-- v15: el líder sale mitad de la prueba y mitad de las misiones cumplidas la semana pasada.
-- Prueba: tu puntaje contra el mejor de la semana (hasta 50). Misiones: 10 por cada una (hasta 50).
-- Solo cuenta quien jugó la prueba. Empate: mejor prueba, luego quien terminó primero.
create or replace function public._tabla_lider(p_semana int)
returns table (jugador_id uuid, puntaje int, misiones int, total numeric, terminado timestamptz)
language sql stable security definer set search_path = public as $$
  with i as (
    select i.jugador_id, greatest(i.puntaje, 0) as puntaje, i.terminado,
           least(5, (select count(*) from public.misiones m
                      where m.semana = p_semana - 1 and m.jugador_id = i.jugador_id and m.cumplida is not null))::int as misiones
      from public.intentos i join public.jugadores j on j.id = i.jugador_id
     where i.semana = p_semana and i.puntaje is not null and j.estado = 'activo' and j.rol = 'jugador'),
  mx as (select greatest(max(puntaje), 1) as m from i)
  select i.jugador_id, i.puntaje, i.misiones, round(50.0 * i.puntaje / mx.m + 10 * i.misiones, 1), i.terminado
    from i, mx
   order by 4 desc, 2 desc, 5 asc
$$;
revoke all on function public._tabla_lider(int) from public, anon, authenticated;

-- Cierra la prueba. Sin p_lider elige al mejor del puntaje combinado (prueba + misiones).
create or replace function public._cerrar_prueba(p_lider uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  c public.config;
  v_lider uuid := p_lider;
begin
  select * into c from public.config where id = 1 for update;
  if c.fase <> 'prueba' then raise exception 'FASE_INCORRECTA'; end if;
  if v_lider is null then
    select t.jugador_id into v_lider from public._tabla_lider(c.semana) t limit 1;
  end if;
  update public.config
     set lider_id = v_lider,
         fase = case when c.ag_semana = c.semana and c.ag_voto_ini > now() then 'espera' else 'votacion' end,
         actualizado = now()
   where id = 1;
  if v_lider is not null then
    insert into public.sucesos (tipo, jugador_id, dato) values ('lider', v_lider, jsonb_build_object('semana', c.semana, 'prueba', c.prueba));
  end if;
  perform public._liquidar('lider', c.semana, case when v_lider is null then '{}'::text[] else array[v_lider::text] end,
                           format('líder de la semana %s', c.semana));
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

  -- gran final: no sale nadie, los lugares se calculan al revelar
  if c.es_final then
    update public.config set eliminado_id = null, empatados = '{}', fase = 'gala', gala_revelada = false, actualizado = now() where id = 1;
    return jsonb_build_object('final', true, 'empate', false);
  end if;

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
    -- v27: el empate se decide EN la pasarela (el líder recibe la llamada de Ricky Reflector)
    update public.config set eliminado_id = null, empatados = v_emp, fase = 'gala', gala_revelada = false,
           llamada_ini = null, llamada_hasta = null, actualizado = now() where id = 1;
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
  if not (p_id = any (c.empatados)) then raise exception 'NO_EMPATADO'; end if;
  if c.fase = 'gala' and c.eliminado_id is null then
    if c.gala_revelada then perform public._resolver_empate(p_id, 'produccion');
    else update public.config set eliminado_id = p_id, actualizado = now() where id = 1; end if;   -- antes de la pasarela
    return;
  end if;
  if c.fase <> 'decision' then raise exception 'NO_EMPATADO'; end if;
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
  if c.fase <> 'gala' or c.gala_revelada or (c.eliminado_id is null and not c.es_final and cardinality(c.empatados) < 2) then raise exception 'FASE_INCORRECTA'; end if;

  res := public._resultados(c.semana);

  -- gran final: menos puntos = mejor lugar; los empatados comparten lugar
  if c.es_final then
    insert into public.historial (semana, resultados) values (c.semana, jsonb_build_object(
      'semana', c.semana, 'final', true,
      'eliminado_id', null, 'eliminado', null, 'lider_id', null, 'lider', null,
      'lider_salvado', false, 'desempate', false,
      'podio', (select jsonb_agg(jsonb_build_object('id', x->>'id', 'nombre', x->>'nombre', 'puntos', (x->>'puntos')::int, 'lugar', lugar)
                                 order by lugar, x->>'nombre')
                  from (select x, dense_rank() over (order by (x->>'puntos')::int) as lugar
                          from jsonb_array_elements(res) x) t),
      'tabla', res))
    on conflict (semana) do update set resultados = excluded.resultados, creado = now();
    update public.config set gala_revelada = true, terminado = true, actualizado = now(),
           ag_semana = null, ag_prueba_ini = null, ag_prueba_fin = null, ag_voto_ini = null, ag_voto_fin = null, ag_gala = null
     where id = 1;
    return;
  end if;
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
    'empatados', to_jsonb(c.empatados),
    'empate_pendiente', c.eliminado_id is null,                  -- v27: lo decide el líder en la pasarela
    'decidio', case when cardinality(c.empatados) > 1 and c.eliminado_id is not null then 'lider' end,
    'resumen', public._resumen_semana(c.semana),
    'tabla', res))
  on conflict (semana) do update set resultados = excluded.resultados, creado = now();

  update public.config set gala_revelada = true, actualizado = now() where id = 1;
  if c.eliminado_id is not null then
    update public.jugadores set estado = 'eliminado', semana_eliminado = c.semana where id = c.eliminado_id;
    perform public._liquidar('eliminado', c.semana, array[c.eliminado_id::text], format('eliminado de la semana %s', c.semana));
  end if;
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
      elsif c.fase = 'gala' and not c.gala_revelada and (c.eliminado_id is not null or c.es_final or cardinality(c.empatados) > 1) and c.ag_gala <= now() then
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
  -- v18: el público no ve los chismes del ojo
  if yo.rol <> 'jugador' then raise exception 'OJO_SOLO_HABITANTES'; end if;
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
  perform public._avisar_produccion('👁️ Chisme por revisar',
    (select case when count(*) = 1 then 'Hay 1 pendiente en el panel (pestaña Ojo).'
                 else format('Hay %s pendientes en el panel (pestaña Ojo).', count(*)) end from public.chismes where pendiente));
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
  if p_fase = 'prueba' and (select es_final from public.config where id = 1) then raise exception 'FASE_INCORRECTA'; end if;
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
  -- temporada nueva: todos regresan a $1,000 (lo que compraron en la tienda se queda)
  delete from public.apuestas where true;
  delete from public.movimientos where true;
  delete from public.misiones where true;
  delete from public.sucesos where true;
  delete from public.practicas where true;
  delete from public.encuestas where liquidada;
  delete from public.duelos where true;
  update public.jugadores set billetes = 2000, ultimo_bono = null where true;
  update public.config set semana = 0, fase = 'registro', prueba = null, lider_id = null, eliminado_id = null,
         empatados = '{}', gala_revelada = false, es_final = false, terminado = false, aviso_voto = null, actualizado = now() where id = 1;
end $$;

-- ---------------------------------------------------------------------
--  AVISOS AL CELULAR
--  La base de datos le pide a la función "avisos" (Edge Function) que
--  mande la notificación. Si la función no está publicada, no pasa nada.
-- ---------------------------------------------------------------------

do $$ begin
  begin create extension if not exists pg_net with schema extensions;
  exception when others then raise notice 'pg_net no está disponible: actívalo en Database → Extensions'; end;
end $$;

create or replace function public._avisar(p_titulo text, p_cuerpo text, p_solo uuid[] default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare a public.push_ajustes;
begin
  select * into a from public.push_ajustes where id = 1;
  if a.clave is null or a.funcion_url is null then return; end if;
  if not exists (select 1 from public.push_subs where p_solo is null or jugador_id = any (p_solo)) then return; end if;
  begin
    perform net.http_post(
      url := a.funcion_url,
      body := jsonb_build_object('titulo', p_titulo, 'cuerpo', p_cuerpo, 'solo', to_jsonb(p_solo)),
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-clave', a.clave),
      timeout_milliseconds := 8000);
  exception when others then null;      -- un aviso que falla nunca detiene el juego
  end;
end $$;

-- Avisos solo para los celulares de la producción
create or replace function public._avisar_produccion(p_titulo text, p_cuerpo text)
returns void language plpgsql security definer set search_path = public as $$
declare v_ids uuid[];
begin
  select array_agg(distinct s.jugador_id) into v_ids
    from public.push_subs s join public.push_produccion p on p.endpoint = s.endpoint;
  if v_ids is null then return; end if;
  perform public._avisar(p_titulo, p_cuerpo, v_ids);
exception when others then null;
end $$;

-- La producción marca este celular para recibir sus avisos (o lo quita)
create or replace function public.admin_push_produccion(p_endpoint text, p_activar boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._solo_admin();
  if not p_activar then delete from public.push_produccion where endpoint = p_endpoint; return; end if;
  if not exists (select 1 from public.push_subs where endpoint = p_endpoint) then raise exception 'SIN_AVISOS'; end if;
  insert into public.push_produccion (endpoint) values (p_endpoint) on conflict do nothing;
  perform public._avisar_produccion('🎬 Avisos de producción activados', 'Aquí te llegará lo que tengas que revisar: votos, chismes, registros y empates.');
end $$;

-- Cada cambio de fase avisa a todos
create or replace function public._config_avisos()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_lider text;
  v_prueba text;
begin
  if new.fase is not distinct from old.fase and new.semana is not distinct from old.semana
     and new.gala_revelada is not distinct from old.gala_revelada then
    return new;
  end if;
  begin
    select nombre into v_lider from public.jugadores where id = new.lider_id;
    v_prueba := case new.prueba when 'trivia' then 'Trivia de la oficina' when 'memoria' then 'Memoria de expedientes'
                                when 'adeudo' then 'Calcula el adeudo' else 'la prueba' end;
    if new.fase = 'prueba' and (old.fase <> 'prueba' or new.semana <> old.semana) then
      perform public._avisar(format('🏆 Semana %s: prueba del líder', new.semana),
                             format('Ya puedes jugar %s. Solo tienes un intento.', v_prueba));
    elsif new.fase = 'espera' and old.fase <> 'espera' then
      if new.es_final then
        perform public._avisar('🏁 ¡Llegamos a la gran final!', 'Sin prueba ni líder: todo se decide con los votos. Ya puedes preparar tu voto.');
      elsif v_lider is not null then
        perform public._avisar(format('👑 %s es el líder de la semana', v_lider), 'La prueba cerró. Ya puedes preparar tu voto en el confesionario.');
      end if;
    elsif new.fase = 'votacion' and old.fase <> 'votacion' then
      if new.es_final then
        perform public._avisar('🏁 ¡Gran final! Ya se puede votar', 'Quien junte menos puntos gana Alfa Brother. Entra al confesionario.');
      else
        perform public._avisar('🗳️ Se abrió la votación',
          case when v_lider is not null and old.fase = 'prueba' then format('%s es el líder 👑. Entra al confesionario a votar.', v_lider)
               else 'Entra al confesionario a votar.' end);
      end if;
    elsif new.fase = 'decision' and old.fase <> 'decision' and new.lider_id is not null then
      perform public._avisar('⚖️ Hubo empate', 'Eres el líder: tú decides quién sale. Entra al juego.', array[new.lider_id]);
    end if;
    if new.fase = 'decision' and old.fase <> 'decision' then
      perform public._avisar_produccion('⚖️ Hubo empate', case when new.lider_id is null then 'No hay líder: tienes que decidir quién sale desde el panel.'
                                                              else 'El líder está decidiendo. Si tarda, puedes decidir tú desde el panel.' end);
    elsif new.fase = 'gala' and new.gala_revelada and not old.gala_revelada then
      if new.terminado then
        perform public._avisar('🏆 ¡Tenemos ganador!', 'Terminó la gran final de Alfa Brother. Entra a ver el podio.');
      else
        perform public._avisar('🎬 ¡Empezó la gala!', 'Entra a ver quién salió de la casa.');
      end if;
    end if;
  exception when others then null;
  end;
  return new;
end $$;
drop trigger if exists config_avisos on public.config;
create trigger config_avisos after update on public.config
  for each row execute function public._config_avisos();

-- Recordatorio: una hora antes de que cierre la votación, a quien no ha votado
create or replace function public._recordatorios()
returns void language plpgsql security definer set search_path = public as $$
declare
  c public.config;
  v_ids uuid[];
begin
  select * into c from public.config where id = 1;
  if c.fase = 'votacion' and c.ag_semana = c.semana and c.ag_voto_fin is not null
     and c.ag_voto_fin > now() and c.ag_voto_fin <= now() + interval '60 minutes'
     and c.aviso_voto is distinct from c.semana then
    update public.config set aviso_voto = c.semana where id = 1 and aviso_voto is distinct from c.semana;
    if not found then return; end if;                       -- otro celular ya lo mandó
    select array_agg(j.id) into v_ids from public.jugadores j
     where not exists (select 1 from public.votos v where v.semana = c.semana and v.votante_id = j.id)
       and exists (select 1 from public.push_subs s where s.jugador_id = j.id);
    if v_ids is not null then
      perform public._avisar('⏰ Última hora para votar', 'La votación cierra en menos de una hora y todavía no votas.', v_ids);
    end if;
  end if;
end $$;

-- El reloj: cada minuto avanza la agenda aunque nadie tenga el juego abierto
create or replace function public._reloj()
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._avanzar_agenda();
  perform public._recordatorios();
  perform public._encuestas();
  begin perform public._noticiero_aviso(); exception when others then null; end;
  begin perform public._cerrar_duelos(); exception when others then null; end;
  begin perform public._empate_vencido(); exception when others then null; end;
end $$;

do $$ begin
  begin create extension if not exists pg_cron with schema pg_catalog;
  exception when others then
    begin create extension if not exists pg_cron;
    exception when others then raise notice 'pg_cron no está disponible: actívalo en Database → Extensions'; end;
  end;
  begin perform cron.schedule('alfa-brother-reloj', '* * * * *', 'select public._reloj()');
  exception when others then raise notice 'No se pudo programar el reloj (falta pg_cron)'; end;
end $$;

-- Llave pública para suscribirse (la privada nunca sale de la base)
create or replace function public.push_clave()
returns text language sql stable security definer set search_path = public as $$
  select vapid_publica from public.push_ajustes where id = 1;
$$;

create or replace function public.guardar_push(p_token uuid, p_sub jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  yo public.jugadores;
  v_end text := p_sub->>'endpoint';
begin
  yo := public._yo(p_token);
  if v_end is null or v_end !~ '^https://' or char_length(v_end) > 1000
     or p_sub->'keys'->>'p256dh' is null or p_sub->'keys'->>'auth' is null then
    raise exception 'SUSCRIPCION_INVALIDA';
  end if;
  insert into public.push_subs (endpoint, sub, jugador_id) values (v_end, p_sub, yo.id)
  on conflict (endpoint) do update set sub = excluded.sub, jugador_id = excluded.jugador_id, creado = now();
  -- máximo 5 celulares por persona
  delete from public.push_subs where jugador_id = yo.id and endpoint in (
    select endpoint from public.push_subs where jugador_id = yo.id order by creado desc offset 5);
end $$;

create or replace function public.borrar_push(p_token uuid, p_endpoint text)
returns void language plpgsql security definer set search_path = public as $$
declare yo public.jugadores;
begin
  yo := public._yo(p_token);
  delete from public.push_subs where endpoint = p_endpoint and jugador_id = yo.id;
end $$;

-- Aviso de prueba solo para mí
create or replace function public.probar_aviso(p_token uuid)
returns void language plpgsql security definer set search_path = public as $$
declare yo public.jugadores;
begin
  yo := public._yo(p_token);
  perform public._avisar('🔔 ¡Avisos activados!', format('Hola, %s. Así te vamos a avisar cuando haya algo nuevo en la casa.', yo.nombre), array[yo.id]);
end $$;

-- La producción manda un aviso a todos
create or replace function public.admin_aviso(p_titulo text, p_cuerpo text)
returns int language plpgsql security definer set search_path = public as $$
begin
  perform public._solo_admin();
  if char_length(btrim(coalesce(p_titulo, ''))) < 2 or char_length(p_titulo) > 60 or char_length(coalesce(p_cuerpo, '')) > 160 then
    raise exception 'AVISO_INVALIDO';
  end if;
  insert into public.anuncios (titulo, cuerpo) values (btrim(p_titulo), nullif(btrim(coalesce(p_cuerpo, '')), ''));
  perform public._avisar(btrim(p_titulo), btrim(coalesce(p_cuerpo, '')));
  return (select count(*) from public.push_subs);
end $$;

-- ---------------------------------------------------------------------
--  CHAT DE LA CASA (solo habitantes: en la casa y eliminados; el público no)
-- ---------------------------------------------------------------------
create or replace function public.chat_leer(p_token uuid, p_desde bigint default 0)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare yo public.jugadores;
begin
  yo := public._yo(p_token);
  if yo.rol <> 'jugador' then raise exception 'SOLO_HABITANTES'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'de', m.jugador_id, 'texto', m.texto,
            'menciones', to_jsonb(m.menciones), 'creado', m.creado) order by m.id), '[]'::jsonb)
            from (select * from public.chat where id > coalesce(p_desde, 0) order by id desc limit 80) m);
end $$;

drop function if exists public.chat_enviar(uuid, text, uuid[]);
create or replace function public.chat_enviar(p_token uuid, p_texto text, p_menciones jsonb default '[]'::jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  yo public.jugadores;
  v text := btrim(regexp_replace(coalesce(p_texto, ''), '[\r\n]{3,}', E'\n\n', 'g'));
  v_men uuid[];
  v_id bigint;
begin
  yo := public._yo(p_token);
  if yo.rol <> 'jugador' then raise exception 'SOLO_HABITANTES'; end if;
  if char_length(v) < 1 or char_length(v) > 300 then raise exception 'MENSAJE_INVALIDO'; end if;
  if exists (select 1 from public.chat where jugador_id = yo.id and creado > now() - interval '1 second') then
    raise exception 'CHAT_RAPIDO';
  end if;
  -- solo se puede mencionar a habitantes, y no a uno mismo
  select coalesce(array_agg(distinct j.id), '{}') into v_men from public.jugadores j
   where j.id::text in (select jsonb_array_elements_text(coalesce(p_menciones, '[]'::jsonb))) and j.rol = 'jugador' and j.id <> yo.id;
  insert into public.chat (jugador_id, texto, menciones) values (yo.id, v, v_men) returning id into v_id;
  if cardinality(v_men) > 0 then
    perform public._avisar(format('💬 %s te mencionó en el chat', yo.nombre), left(v, 120), v_men);
  end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
--  BILLETES ALFA
-- ---------------------------------------------------------------------

create or replace function public._hoy()
returns date language sql stable as $$ select (now() at time zone 'America/Mexico_City')::date $$;

-- Mueve billetes y deja el registro. Nadie puede quedar en negativo.
create or replace function public._mover(p_jugador uuid, p_monto int, p_concepto text)
returns int language plpgsql security definer set search_path = public as $$
declare v int;
begin
  if coalesce(p_monto, 0) = 0 then return (select billetes from public.jugadores where id = p_jugador); end if;
  update public.jugadores set billetes = billetes + p_monto
   where id = p_jugador and billetes + p_monto >= 0 returning billetes into v;
  if not found then raise exception 'SIN_BILLETES'; end if;
  insert into public.movimientos (jugador_id, monto, concepto) values (p_jugador, p_monto, left(p_concepto, 120));
  return v;
end $$;

-- Reparte un pozo: lo apostado se divide entre los que atinaron según cuánto puso cada uno.
-- Si nadie atinó, se devuelve todo.
create or replace function public._liquidar(p_tipo text, p_ref bigint, p_ganadores text[], p_titulo text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_total bigint;
  v_win bigint;
  v int;
  a public.apuestas;
begin
  select coalesce(sum(monto), 0), coalesce(sum(monto) filter (where opcion = any (coalesce(p_ganadores, '{}'))), 0)
    into v_total, v_win
    from public.apuestas where tipo = p_tipo and ref = p_ref and pago is null;
  if v_total = 0 then return; end if;
  for a in select * from public.apuestas where tipo = p_tipo and ref = p_ref and pago is null for update loop
    if v_win = 0 then
      update public.apuestas set pago = a.monto where id = a.id;
      perform public._mover(a.jugador_id, a.monto, 'Nadie le atinó (' || p_titulo || '): te devolvemos tu apuesta');
    elsif a.opcion = any (p_ganadores) then
      v := floor(a.monto::numeric * v_total / v_win);
      update public.apuestas set pago = v where id = a.id;
      perform public._mover(a.jugador_id, v, '¡Ganaste la apuesta: ' || p_titulo || '!');
    else
      update public.apuestas set pago = 0 where id = a.id;
    end if;
  end loop;
end $$;

-- Apostar (o cambiar la apuesta; monto 0 la quita)
create or replace function public.apostar(p_token uuid, p_tipo text, p_opcion text, p_monto int, p_ref bigint default null)
returns int language plpgsql security definer set search_path = public as $$
declare
  yo public.jugadores;
  c public.config;
  e public.encuestas;
  v_ref bigint;
  v_prev public.apuestas;
  v_titulo text;
begin
  yo := public._yo(p_token);
  if yo.rol <> 'jugador' then raise exception 'PUBLICO_SIN_BILLETES'; end if;      -- v21: el público junta billetes pero no los usa
  select * into c from public.config where id = 1;
  if p_monto is null or p_monto < 0 or (p_monto > 0 and p_monto < 10) then raise exception 'APUESTA_MINIMA'; end if;
  if p_monto > 5000 then raise exception 'APUESTA_MAXIMA'; end if;

  if p_tipo = 'lider' then
    if c.fase <> 'prueba' or c.es_final then raise exception 'APUESTAS_CERRADAS'; end if;
    v_ref := c.semana; v_titulo := format('líder de la semana %s', c.semana);
    if p_monto > 0 and not exists (select 1 from public.jugadores where id::text = p_opcion and rol = 'jugador' and estado = 'activo') then
      raise exception 'OPCION_INVALIDA';
    end if;
  elsif p_tipo = 'eliminado' then
    if c.semana = 0 or c.es_final or c.fase not in ('prueba', 'espera', 'votacion') then raise exception 'APUESTAS_CERRADAS'; end if;
    v_ref := c.semana; v_titulo := format('eliminado de la semana %s', c.semana);
    if p_monto > 0 and not exists (select 1 from public.jugadores where id::text = p_opcion and rol = 'jugador' and estado = 'activo') then
      raise exception 'OPCION_INVALIDA';
    end if;
    if p_monto > 0 and p_opcion = c.lider_id::text then raise exception 'ES_LIDER'; end if;
  elsif p_tipo = 'encuesta' then
    select * into e from public.encuestas where id = p_ref;
    if not found or e.abre > now() or e.cierra <= now() then raise exception 'APUESTAS_CERRADAS'; end if;
    v_ref := e.id; v_titulo := format('encuesta "%s"', left(e.pregunta, 60));
    if p_monto > 0 and (p_opcion !~ '^[0-9]+$' or p_opcion::int >= jsonb_array_length(e.opciones)) then raise exception 'OPCION_INVALIDA'; end if;
  else
    raise exception 'OPCION_INVALIDA';
  end if;

  select * into v_prev from public.apuestas where tipo = p_tipo and ref = v_ref and jugador_id = yo.id for update;
  if found then
    if v_prev.pago is not null then raise exception 'APUESTAS_CERRADAS'; end if;
    delete from public.apuestas where id = v_prev.id;
    perform public._mover(yo.id, v_prev.monto, 'Quitaste tu apuesta: ' || v_titulo);
  end if;
  if p_monto > 0 then
    perform public._mover(yo.id, -p_monto, 'Apuesta: ' || v_titulo);
    insert into public.apuestas (tipo, ref, jugador_id, opcion, monto) values (p_tipo, v_ref, yo.id, p_opcion, p_monto);
  end if;
  return (select billetes from public.jugadores where id = yo.id);
end $$;

-- Mis últimos movimientos
create or replace function public.mis_billetes(p_token uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare yo public.jugadores;
begin
  yo := public._yo(p_token);
  return jsonb_build_object('billetes', yo.billetes, 'movimientos',
    (select coalesce(jsonb_agg(jsonb_build_object('monto', m.monto, 'concepto', m.concepto, 'creado', m.creado) order by m.creado desc, m.id desc), '[]'::jsonb)
       from (select * from public.movimientos where jugador_id = yo.id order by creado desc, id desc limit 40) m),
    'ranking', (select coalesce(jsonb_agg(jsonb_build_object('id', j.id, 'nombre', j.nombre, 'billetes', j.billetes) order by j.billetes desc, j.nombre), '[]'::jsonb)
       from public.jugadores j));
end $$;

-- La producción da o quita billetes (premios especiales)
create or replace function public.admin_billetes(p_id uuid, p_monto int, p_concepto text)
returns int language plpgsql security definer set search_path = public as $$
begin
  perform public._solo_admin();
  return public._mover(p_id, p_monto, coalesce(nullif(btrim(p_concepto), ''), 'Premio de la producción'));
end $$;

-- ---------------------------------------------------------------------
--  ENCUESTA DEL DÍA
-- ---------------------------------------------------------------------

-- Abre y cierra encuestas según su hora (lo llama el reloj y cada celular)
create or replace function public._encuestas()
returns void language plpgsql security definer set search_path = public as $$
declare
  e public.encuestas;
  v_conteo jsonb;
  v_max int;
  v_gan text[];
  v_txt text;
begin
  if not exists (select 1 from public.encuestas
                  where (not avisada and abre <= now()) or (not liquidada and cierra <= now())) then
    return;
  end if;
  for e in select * from public.encuestas where not avisada and abre <= now() and cierra > now() for update skip locked loop
    update public.encuestas set avisada = true where id = e.id;
    perform public._avisar('📊 Encuesta del día', e.pregunta || ' Vota y apuesta antes de que cierre.');
  end loop;
  for e in select * from public.encuestas where not liquidada and cierra <= now() for update skip locked loop
    select coalesce(jsonb_agg(n order by i), '[]'::jsonb), coalesce(max(n), 0),
           array_agg(i::text order by i) filter (where n > 0 and n = (select max(n2) from (
             select (select count(*) from public.encuesta_votos v join public.jugadores j on j.id = v.jugador_id and j.rol = 'jugador'
                      where v.encuesta_id = e.id and v.opcion = i2)::int n2
               from generate_series(0, jsonb_array_length(e.opciones) - 1) i2) z))
      into v_conteo, v_max, v_gan
      from (select i, (select count(*) from public.encuesta_votos v join public.jugadores j on j.id = v.jugador_id and j.rol = 'jugador'
                        where v.encuesta_id = e.id and v.opcion = i)::int n
              from generate_series(0, jsonb_array_length(e.opciones) - 1) i) t;
    update public.encuestas set liquidada = true, avisada = true,
           resultado = jsonb_build_object('conteo', v_conteo, 'ganadores', to_jsonb(coalesce(v_gan, '{}'::text[])))
     where id = e.id;
    perform public._liquidar('encuesta', e.id, coalesce(v_gan, '{}'::text[]), format('encuesta "%s"', left(e.pregunta, 60)));
    select string_agg(e.opciones->(g::int)->>'t', ' y ') into v_txt from unnest(coalesce(v_gan, '{}'::text[])) g;
    perform public._avisar('📊 Resultado de la encuesta',
      case when v_txt is null then e.pregunta || ' Nadie votó.' else e.pregunta || ' Ganó: ' || v_txt end);
  end loop;
end $$;

create or replace function public.votar_encuesta(p_token uuid, p_id bigint, p_opcion int)
returns void language plpgsql security definer set search_path = public as $$
declare
  yo public.jugadores;
  e public.encuestas;
begin
  yo := public._yo(p_token);
  select * into e from public.encuestas where id = p_id;
  if not found or e.abre > now() or e.cierra <= now() then raise exception 'ENCUESTA_CERRADA'; end if;
  if p_opcion is null or p_opcion < 0 or p_opcion >= jsonb_array_length(e.opciones) then raise exception 'OPCION_INVALIDA'; end if;
  insert into public.encuesta_votos (encuesta_id, jugador_id, opcion) values (p_id, yo.id, p_opcion)
  on conflict (encuesta_id, jugador_id) do update set opcion = excluded.opcion;
end $$;

-- Borrar una encuesta devuelve lo apostado
create or replace function public.admin_borrar_encuesta(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._solo_admin();
  perform public._liquidar('encuesta', p_id, '{}'::text[], 'encuesta cancelada');
  delete from public.apuestas where tipo = 'encuesta' and ref = p_id;
  delete from public.encuestas where id = p_id;
end $$;

-- ---------------------------------------------------------------------
--  MISIONES SECRETAS
-- ---------------------------------------------------------------------

create or replace function public._codigo()
returns text language sql volatile as $$
  select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '') from generate_series(1, 6)
$$;

-- Cada quien recibe una misión distinta; todos son objetivo de exactamente una persona.
create or replace function public._repartir_misiones(p_semana int, p_reemplazar boolean)
returns int language plpgsql security definer set search_path = public as $$
-- Todos los habitantes (en la casa y eliminados; el público no). Cada quien recibe 5 misiones con 5 objetivos distintos
-- (si quedan pocos se repiten). En cada ronda todos son objetivo de exactamente una persona.
declare
  v_ids uuid[];
  v_txt text[];
  n int;
  i int;
  r int;
  k int;
  v_obj uuid;
  v_num int;
  v_hechas int := 0;
begin
  if p_semana < 1 then return 0; end if;
  if p_reemplazar then delete from public.misiones where semana = p_semana and cumplida is null; end if;
  select array_agg(j.id order by random()) into v_ids from public.jugadores j where j.rol = 'jugador';
  n := coalesce(array_length(v_ids, 1), 0);
  if n < 2 then return 0; end if;
  select array_agg(texto order by random()) into v_txt from public.misiones_banco where activa;
  if v_txt is null then return 0; end if;
  r := 0;
  for k in 1..20 loop                                   -- rondas (se salta la que caería en uno mismo)
    exit when r >= 5;
    continue when k % n = 0;
    r := r + 1;
    for i in 1..n loop
      -- ¿le falta una misión en este número?
      select min(x) into v_num from generate_series(1, 5) x
       where not exists (select 1 from public.misiones m where m.semana = p_semana and m.jugador_id = v_ids[i] and m.n = x);
      continue when v_num is null;
      v_obj := v_ids[1 + (i - 1 + k) % n];
      insert into public.misiones (semana, jugador_id, objetivo_id, n, texto, codigo)
      values (p_semana, v_ids[i], v_obj, v_num,
              replace(v_txt[1 + ((i - 1) * 5 + r - 1) % array_length(v_txt, 1)], '{nombre}', (select nombre from public.jugadores where id = v_obj)),
              public._codigo());
      v_hechas := v_hechas + 1;
    end loop;
  end loop;
  return v_hechas;
end $$;

-- v14: quien cumplió la misión toca "¡Ya la cumplí!" y a la otra persona le llega el aviso para confirmar
drop function if exists public.confirmar_mision(uuid, text);
create or replace function public.reclamar_mision(p_token uuid, p_n int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  yo public.jugadores;
  m public.misiones;
begin
  yo := public._yo(p_token);
  select * into m from public.misiones
   where semana = (select semana from public.config where id = 1) and jugador_id = yo.id and n = p_n for update;
  if not found then raise exception 'MISION_NO_EXISTE'; end if;
  if m.cumplida is not null then raise exception 'MISION_YA_CUMPLIDA'; end if;
  if m.pedida is not null then raise exception 'MISION_YA_PEDIDA'; end if;
  update public.misiones set pedida = now() where id = m.id;
  perform public._avisar('🕵️ ¿Es cierto?', format('%s dice que cumplió una misión secreta contigo. Entra a confirmarlo.', yo.nombre), array[m.objetivo_id]);
  return jsonb_build_object('objetivo_id', m.objetivo_id);
end $$;

-- La persona de la misión responde: es cierto (los dos ganan) o es falso (se cancela y la misión sigue pendiente)
create or replace function public.responder_mision(p_token uuid, p_id bigint, p_ok boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  yo public.jugadores;
  m public.misiones;
  v_de text;
begin
  yo := public._yo(p_token);
  select * into m from public.misiones where id = p_id for update;
  if not found then raise exception 'MISION_NO_EXISTE'; end if;
  if m.objetivo_id <> yo.id then raise exception 'NO_ERES_OBJETIVO'; end if;
  if m.cumplida is not null then raise exception 'MISION_YA_CUMPLIDA'; end if;
  if m.pedida is null then raise exception 'MISION_SIN_PEDIR'; end if;
  if m.semana <> (select semana from public.config where id = 1) then
    raise exception 'MISION_VENCIDA';
  end if;
  v_de := (select nombre from public.jugadores where id = m.jugador_id);
  if coalesce(p_ok, false) then
    update public.misiones set cumplida = now(), pedida = null where id = m.id;
    perform public._mover(m.jugador_id, 300, 'Misión secreta cumplida');
    perform public._mover(yo.id, 50, 'Confirmaste una misión secreta');
    perform public._avisar('🕵️ ¡Misión cumplida!', format('%s confirmó tu misión. Ganaste $300 (%s de 5).', yo.nombre,
      (select count(*) from public.misiones where semana = m.semana and jugador_id = m.jugador_id and cumplida is not null)), array[m.jugador_id]);
  else
    update public.misiones set pedida = null where id = m.id;
    perform public._avisar('🕵️ Misión rechazada', format('%s dijo que es falso. Tu misión sigue pendiente.', yo.nombre), array[m.jugador_id]);
  end if;
  return jsonb_build_object('ok', coalesce(p_ok, false), 'texto', m.texto, 'de', v_de);
end $$;

create or replace function public.admin_repartir_misiones()
returns int language plpgsql security definer set search_path = public as $$
begin
  perform public._solo_admin();
  return public._repartir_misiones((select semana from public.config where id = 1), true);
end $$;

-- Banco inicial de misiones (solo se agregan las que falten)
insert into public.misiones_banco (texto) values
  ('Haz que {nombre} diga la palabra "pagaré".'),
  ('Consigue que {nombre} te preste una pluma.'),
  ('Haz que {nombre} se ría de un chiste tuyo.'),
  ('Logra que {nombre} te dé los buenos días primero.'),
  ('Haz que {nombre} diga "Alfa Brother".'),
  ('Consigue que {nombre} te choque la mano.'),
  ('Haz que {nombre} te cuente qué desayunó hoy.'),
  ('Logra que {nombre} diga "te vamos a cobrar".'),
  ('Consigue que {nombre} te recomiende una serie o una película.'),
  ('Haz que {nombre} te diga cuál es su canción favorita.'),
  ('Logra que {nombre} diga la palabra "moroso".'),
  ('Haz que {nombre} se tome una selfie contigo.'),
  ('Consigue que {nombre} te convide algo de comer, aunque sea un dulce.'),
  ('Haz que {nombre} diga "¡qué calor!".'),
  ('Logra que {nombre} te pregunte la hora.'),
  ('Haz que {nombre} diga "ya mero es quincena".'),
  ('Consigue que {nombre} cante un pedacito de una canción.'),
  ('Haz que {nombre} te cuente un apodo que tenía de niño.'),
  ('Logra que {nombre} use la palabra "intereses" en una frase.'),
  ('Haz que {nombre} diga "mañana te pago".'),
  ('Logra que {nombre} te diga cuál es su comida favorita.'),
  ('Haz que {nombre} diga "¿y la ruta de hoy?".'),
  ('Consigue que {nombre} te dé un consejo.'),
  ('Haz que {nombre} diga tu nombre completo.'),
  ('Haz que {nombre} diga "estoy en junta".'),
  ('Consigue que {nombre} te cuente un chiste.'),
  ('Haz que {nombre} diga "el cliente no contesta".'),
  ('Logra que {nombre} te diga a dónde se iría de vacaciones.'),
  ('Haz que {nombre} diga "Big Brother".'),
  ('Consigue que {nombre} te pida un favor.'),
  ('Logra que {nombre} te haga un cumplido.'),
  ('Haz que {nombre} adivine tu color favorito.'),
  ('Consigue que {nombre} diga "¡no manches!".'),
  ('Haz que {nombre} te ofrezca café o agua.'),
  ('Logra que {nombre} diga "ahorita" en una frase.'),
  ('Haz que {nombre} te pregunte cómo va tu semana.'),
  ('Consigue que {nombre} te diga qué superpoder le gustaría tener.'),
  ('Haz que {nombre} diga "¡ya llegó el cobrador!".'),
  ('Logra que {nombre} te enseñe a hacer algo que sabe hacer.'),
  ('Haz que {nombre} diga la palabra "liquidar".')
on conflict (texto) do nothing;

-- ---------------------------------------------------------------------
--  RÉCORDS DE LA CASA
-- ---------------------------------------------------------------------

create or replace function public.guardar_practica(p_token uuid, p_juego text, p_puntaje int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  yo public.jugadores;
  v int;
  v_rec int;
  p public.practicas;
  v_premio int := 0;
  v_record boolean := false;
begin
  yo := public._yo(p_token);
  if p_juego not in ('memoria', 'adeudo', 'monster', 'monster2') then raise exception 'JUEGO_INVALIDO'; end if;
  v := least(greatest(coalesce(p_puntaje, 0), 0), case p_juego when 'memoria' then 1000 when 'adeudo' then 20000 else 5000000 end);
  select coalesce(max(p2.mejor), 0) into v_rec from public.practicas p2 join public.jugadores j on j.id = p2.jugador_id and j.rol = 'jugador' where p2.juego = p_juego;
  insert into public.practicas (jugador_id, juego) values (yo.id, p_juego) on conflict do nothing;
  select * into p from public.practicas where jugador_id = yo.id and juego = p_juego for update;
  if p.ultimo_premio is distinct from public._hoy() then
    perform public._mover(yo.id, 100, 'Práctica del día'); v_premio := 100;
  end if;
  if v > v_rec and v > 0 and yo.rol = 'jugador' then        -- el público guarda su mejor marca, pero no cuenta para los récords de la casa
    v_record := true;
    insert into public.sucesos (tipo, jugador_id, dato) values ('record', yo.id, jsonb_build_object('juego', p_juego, 'puntos', v, 'antes', v_rec));
    if p.ultimo_record is distinct from public._hoy() then
      perform public._mover(yo.id, 200, 'Nuevo récord de la casa'); v_premio := v_premio + 200;
    end if;
  end if;
  update public.practicas
     set mejor = greatest(mejor, v), partidas = partidas + 1, ultimo_premio = public._hoy(),
         ultimo_record = case when v_record then public._hoy() else ultimo_record end
   where jugador_id = yo.id and juego = p_juego;
  return jsonb_build_object('mejor', greatest(p.mejor, v), 'record', v_record, 'premio', v_premio,
    'premio_dia', case when p.ultimo_premio is distinct from public._hoy() then 100 else 0 end,
    'top', (select coalesce(jsonb_agg(jsonb_build_object('id', t.jugador_id, 'nombre', j.nombre, 'mejor', t.mejor) order by t.mejor desc), '[]'::jsonb)
              from (select p3.* from public.practicas p3 join public.jugadores j3 on j3.id = p3.jugador_id and j3.rol = 'jugador'
                     where p3.juego = p_juego and p3.mejor > 0 order by p3.mejor desc limit 5) t
              join public.jugadores j on j.id = t.jugador_id));
end $$;

-- ---------------------------------------------------------------------
--  TIENDA DEL MONITO
-- ---------------------------------------------------------------------

-- v10: tienda más cara y con mascotas y efectos
alter table public.tienda drop constraint if exists tienda_tipo_check;
alter table public.tienda add constraint tienda_tipo_check check (tipo in ('sombrero','lentes','color','mano','mascota','efecto'));

insert into public.tienda (id, tipo, nombre, icono, precio, orden) values
  -- sombreros
  ('moño',       'sombrero', 'Moño',               '🎀',   500, 1),
  ('flor',       'sombrero', 'Flor',               '🌸',   500, 2),
  ('gorra',      'sombrero', 'Gorra',              '🧢',   600, 3),
  ('casco',      'sombrero', 'Casco',              '⛑️',   800, 4),
  ('pamela',     'sombrero', 'Sombrero',           '👒',   900, 5),
  ('militar',    'sombrero', 'Casco militar',      '🪖',  1000, 6),
  ('birrete',    'sombrero', 'Birrete',            '🎓',  1200, 7),
  ('hongo',      'sombrero', 'Hongo',              '🍄',  1500, 8),
  ('copa',       'sombrero', 'Sombrero de copa',   '🎩',  1800, 9),
  ('calabaza',   'sombrero', 'Calabaza',           '🎃',  2000, 10),
  ('arbolito',   'sombrero', 'Arbolito',           '🎄',  2200, 11),
  ('pulpo',      'sombrero', 'Pulpo',              '🐙',  2500, 12),
  ('unicornio',  'sombrero', 'Unicornio',          '🦄',  3500, 13),
  -- lentes
  ('lentes',     'lentes',   'Lentes',             '👓',   500, 1),
  ('goggles',    'lentes',   'Goggles',            '🥽',   900, 2),
  ('oscuros',    'lentes',   'Lentes oscuros',     '🕶️',  1200, 3),
  ('buceo',      'lentes',   'Visor de buceo',     '🤿',  1500, 4),
  ('disfraz',    'lentes',   'Disfraz secreto',    '🥸',  2000, 5),
  -- color del cuerpo
  ('rojo',       'color',    'Rojo',               '#FF4D5E',  400, 1),
  ('azul',       'color',    'Azul',               '#4D8DFF',  400, 2),
  ('verde',      'color',    'Verde',              '#2ED198',  400, 3),
  ('rosa',       'color',    'Rosa',               '#FF6FB5',  400, 4),
  ('morado',     'color',    'Morado',             '#A974FF',  400, 5),
  ('naranja',    'color',    'Naranja',            '#FF9F43',  400, 6),
  ('turquesa',   'color',    'Turquesa',           '#2EE6D6',  500, 7),
  ('plata',      'color',    'Plata',              '#C9D2E3', 1500, 8),
  ('dorado',     'color',    'Dorado',             '#FFC93C', 3000, 9),
  ('arcoiris',   'color',    'Arcoíris',           'arcoiris', 5000, 10),
  -- en la mano
  ('cafe',       'mano',     'Café',               '☕',   400, 1),
  ('portapapel', 'mano',     'Portapapeles',       '📋',   400, 2),
  ('cel',        'mano',     'Celular',            '📱',   600, 3),
  ('taco',       'mano',     'Taco',               '🌮',   600, 4),
  ('pizza',      'mano',     'Pizza',              '🍕',   700, 5),
  ('maletin',    'mano',     'Maletín',            '💼',   800, 6),
  ('globo',      'mano',     'Globo',              '🎈',   800, 7),
  ('rosa_flor',  'mano',     'Rosa',               '🌹',   900, 8),
  ('micro',      'mano',     'Micrófono',          '🎤',  1000, 9),
  ('extintor',   'mano',     'Extintor',           '🧯',  1200, 10),
  ('fajo',       'mano',     'Fajo de billetes',   '💵',  1500, 11),
  ('guitarra',   'mano',     'Guitarra',           '🎸',  2000, 12),
  ('varita',     'mano',     'Varita mágica',      '🪄',  2500, 13),
  ('trofeo',     'mano',     'Trofeo',             '🏆',  4000, 14),
  -- mascotas (caminan contigo)
  ('pollito',    'mascota',  'Pollito',            '🐣',  1800, 1),
  ('tortuga',    'mascota',  'Tortuga',            '🐢',  2000, 2),
  ('cerdito',    'mascota',  'Cerdito',            '🐷',  2200, 3),
  ('perrito',    'mascota',  'Perrito',            '🐶',  2500, 4),
  ('gatito',     'mascota',  'Gatito',             '🐱',  2500, 5),
  ('perico',     'mascota',  'Perico',             '🦜',  3000, 6),
  ('dino',       'mascota',  'Dinosaurio',         '🦖',  5000, 7),
  ('dragon',     'mascota',  'Dragón',             '🐉',  8000, 8),
  -- efectos (flotan alrededor)
  ('brillos',    'efecto',   'Brillitos',          '✨',  3000, 1),
  ('nieve',      'efecto',   'Nieve',              '❄️',  3000, 2),
  ('corazones',  'efecto',   'Corazones',          '💖',  3500, 3),
  ('estrellas',  'efecto',   'Estrellas',          '⭐',  4000, 4),
  ('llamas',     'efecto',   'En llamas',          '🔥',  5000, 5),
  ('billetes',   'efecto',   'Lluvia de billetes', '💸',  6000, 6)
on conflict (id) do update set tipo = excluded.tipo, nombre = excluded.nombre, icono = excluded.icono,
                               precio = excluded.precio, orden = excluded.orden;

create or replace function public.tienda_lista()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'tipo', tipo, 'nombre', nombre, 'icono', icono, 'precio', precio)
                  order by tipo, orden), '[]'::jsonb) from public.tienda;
$$;

create or replace function public.comprar(p_token uuid, p_item text)
returns int language plpgsql security definer set search_path = public as $$
declare
  yo public.jugadores;
  t public.tienda;
begin
  yo := public._yo(p_token);
  if yo.rol <> 'jugador' then raise exception 'PUBLICO_SIN_BILLETES'; end if;
  select * into t from public.tienda where id = p_item;
  if not found then raise exception 'OPCION_INVALIDA'; end if;
  if p_item = any (yo.compras) then raise exception 'YA_LO_TIENES'; end if;
  perform public._mover(yo.id, -t.precio, 'Tienda: ' || t.nombre);
  update public.jugadores set compras = array_append(compras, p_item), estilo = estilo || jsonb_build_object(t.tipo, t.id)
   where id = yo.id;
  return (select billetes from public.jugadores where id = yo.id);
end $$;

create or replace function public.equipar(p_token uuid, p_tipo text, p_item text)
returns void language plpgsql security definer set search_path = public as $$
declare yo public.jugadores;
begin
  yo := public._yo(p_token);
  if p_item is null then
    update public.jugadores set estilo = estilo - p_tipo where id = yo.id;
    return;
  end if;
  if not (p_item = any (yo.compras)) or not exists (select 1 from public.tienda where id = p_item and tipo = p_tipo) then
    raise exception 'OPCION_INVALIDA';
  end if;
  update public.jugadores set estilo = estilo || jsonb_build_object(p_tipo, p_item) where id = yo.id;
end $$;

-- ---------------------------------------------------------------------
--  Lo que el celular necesita de la economía (se suma a estado())
-- ---------------------------------------------------------------------
create or replace function public._economia(p_yo uuid, p_bono int)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  c public.config;
  yo public.jugadores;
begin
  select * into c from public.config where id = 1;
  select * into yo from public.jugadores where id = p_yo;
  return jsonb_build_object(
    'billetes', yo.billetes,
    'bono', p_bono,
    'compras', to_jsonb(yo.compras),
    'mi_estilo', yo.estilo,
    'mis_apuestas', (select coalesce(jsonb_agg(jsonb_build_object('tipo', a.tipo, 'ref', a.ref, 'opcion', a.opcion, 'monto', a.monto, 'pago', a.pago)), '[]'::jsonb)
        from public.apuestas a where a.jugador_id = p_yo
         and ((a.tipo in ('lider', 'eliminado') and a.ref = c.semana)
           or (a.tipo = 'encuesta' and a.ref in (select id from public.encuestas where cierra > now() - interval '24 hours')))),
    'pozos', jsonb_build_object(
        'lider', (select coalesce(sum(monto), 0) from public.apuestas where tipo = 'lider' and ref = c.semana),
        'eliminado', (select coalesce(sum(monto), 0) from public.apuestas where tipo = 'eliminado' and ref = c.semana),
        'apostadores_lider', (select count(*) from public.apuestas where tipo = 'lider' and ref = c.semana),
        'apostadores_eliminado', (select count(*) from public.apuestas where tipo = 'eliminado' and ref = c.semana)),
    'encuestas', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', e.id, 'pregunta', e.pregunta, 'opciones', e.opciones, 'abre', e.abre, 'cierra', e.cierra,
          'abierta', e.abre <= now() and e.cierra > now(),
          'votos', (select count(*) from public.encuesta_votos v join public.jugadores j on j.id = v.jugador_id and j.rol = 'jugador' where v.encuesta_id = e.id),
          'mi_voto', (select v.opcion from public.encuesta_votos v where v.encuesta_id = e.id and v.jugador_id = p_yo),
          'pozo', (select coalesce(sum(monto), 0) from public.apuestas a where a.tipo = 'encuesta' and a.ref = e.id),
          'resultado', case when e.liquidada then e.resultado end) order by e.cierra), '[]'::jsonb)
        -- v23: las encuestas cerradas se ven solo el mismo día en que cerraron (hora de la Ciudad de México);
        -- al día siguiente ya no salen en la app, pero el registro se queda en el panel de producción
        from public.encuestas e where e.abre <= now()
          and (e.cierra > now() or (e.cierra at time zone 'America/Mexico_City')::date = (now() at time zone 'America/Mexico_City')::date)),
    'proxima_encuesta', (select min(abre) from public.encuestas where abre > now()),
    'chat_ultimo', case when yo.rol = 'jugador' then (select max(id) from public.chat) end,
    'anuncios', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'titulo', a.titulo, 'cuerpo', a.cuerpo, 'creado', a.creado) order by a.id desc), '[]'::jsonb)
        from (select * from public.anuncios order by id desc limit 30) a),
    'misiones', (select coalesce(jsonb_agg(jsonb_build_object('n', m.n, 'texto', m.texto, 'objetivo_id', m.objetivo_id, 
          'cumplida', m.cumplida is not null, 'pedida', m.pedida is not null) order by m.n), '[]'::jsonb)
        from public.misiones m where m.semana = c.semana and m.jugador_id = p_yo),
    -- misiones que alguien dice que cumplió conmigo y esperan mi respuesta
    'por_confirmar', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'de', m.jugador_id, 'texto', m.texto) order by m.pedida), '[]'::jsonb)
        from public.misiones m where m.semana = c.semana and m.objetivo_id = p_yo and m.pedida is not null and m.cumplida is null),
    -- todos (también el público) ven cuántas lleva cada habitante
    'progreso_misiones', (select coalesce(jsonb_agg(jsonb_build_object('id', x.jugador_id, 'hechas', x.hechas, 'total', x.total)
          order by x.hechas desc, x.jugador_id), '[]'::jsonb)
        from (select jugador_id, count(*) filter (where cumplida is not null)::int as hechas, count(*)::int as total
                from public.misiones where semana = c.semana group by jugador_id) x),
    'misiones_cumplidas', (select count(*) from public.misiones where semana = c.semana and cumplida is not null),
    'records', (select coalesce(jsonb_agg(jsonb_build_object('juego', r.juego, 'id', r.jugador_id, 'mejor', r.mejor) order by r.juego, r.mejor desc), '[]'::jsonb)
        from (select p.*, row_number() over (partition by p.juego order by p.mejor desc, p.jugador_id) as n
                from public.practicas p join public.jugadores jj on jj.id = p.jugador_id and jj.rol = 'jugador' where p.mejor > 0) r where r.n <= 3),
    'practicas', (select coalesce(jsonb_agg(jsonb_build_object('id', p.jugador_id, 'juego', p.juego, 'mejor', p.mejor, 'partidas', p.partidas)), '[]'::jsonb)
        from public.practicas p)
  );
end $$;

-- ---------------------------------------------------------------------
--  v19: EL NOTICIERAZO — lo que pasó ayer, para los presentadores
-- ---------------------------------------------------------------------
alter table public.config add column if not exists noticiero_aviso date;

-- La edición de cada día sale a las 9 a.m. (v22) y cuenta el día anterior (hora de la Ciudad de México)
create or replace function public._noticiero_dia()
returns date language sql stable as $$
  select ((now() at time zone 'America/Mexico_City') - interval '9 hours')::date - 1
$$;

-- p_avance (solo la producción): el noticiero que saldrá la próxima mañana, con lo que va del día
drop function if exists public.noticiero(uuid);
create or replace function public.noticiero(p_token uuid, p_avance boolean default false)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_dia date := public._noticiero_dia() + case when p_avance then 1 else 0 end;
  v_ini timestamptz := (v_dia::timestamp) at time zone 'America/Mexico_City';
  v_fin timestamptz := ((v_dia + 1)::timestamp) at time zone 'America/Mexico_City';
begin
  if p_avance then
    if not public.es_admin() then raise exception 'NO_AUTORIZADO'; end if;
  else
    perform public._yo(p_token);
  end if;
  return jsonb_build_object(
    'dia', v_dia, 'avance', p_avance,
    'galas', (select coalesce(jsonb_agg(h.resultados order by h.semana), '[]'::jsonb)
        from public.historial h where h.creado >= v_ini and h.creado < v_fin),
    'sucesos', (select coalesce(jsonb_agg(jsonb_build_object('tipo', s.tipo, 'id', s.jugador_id, 'nombre', j.nombre, 'dato', s.dato) order by s.id), '[]'::jsonb)
        from public.sucesos s left join public.jugadores j on j.id = s.jugador_id where s.creado >= v_ini and s.creado < v_fin),
    'compras', (select coalesce(jsonb_agg(jsonb_build_object('id', m.jugador_id, 'nombre', j.nombre, 'cosa', substr(m.concepto, 9)) order by m.id), '[]'::jsonb)
        from public.movimientos m join public.jugadores j on j.id = m.jugador_id and j.rol = 'jugador'
       where m.concepto like 'Tienda: %' and m.creado >= v_ini and m.creado < v_fin),
    'misiones', (select coalesce(jsonb_agg(jsonb_build_object('id', x.jugador_id, 'nombre', j.nombre, 'n', x.n) order by x.n desc, j.nombre), '[]'::jsonb)
        from (select jugador_id, count(*)::int as n from public.movimientos
               where concepto = 'Misión secreta cumplida' and creado >= v_ini and creado < v_fin group by jugador_id) x
        join public.jugadores j on j.id = x.jugador_id and j.rol = 'jugador'),
    'apuestas', (select coalesce(jsonb_agg(jsonb_build_object('id', m.jugador_id, 'nombre', j.nombre, 'monto', m.monto) order by m.monto desc), '[]'::jsonb)
        from public.movimientos m join public.jugadores j on j.id = m.jugador_id and j.rol = 'jugador'
       where m.concepto like '¡Ganaste la apuesta%' and m.creado >= v_ini and m.creado < v_fin),
    'encuestas', (select coalesce(jsonb_agg(jsonb_build_object('pregunta', e.pregunta, 'opciones', e.opciones, 'resultado', e.resultado) order by e.cierra), '[]'::jsonb)
        from public.encuestas e where e.liquidada and e.cierra >= v_ini and e.cierra < v_fin),
    'chat', jsonb_build_object(
        'n', (select count(*) from public.chat c join public.jugadores j on j.id = c.jugador_id and j.rol = 'jugador' where c.creado >= v_ini and c.creado < v_fin),
        'top', (select jsonb_build_object('id', c.jugador_id, 'nombre', j.nombre, 'n', count(*))
                  from public.chat c join public.jugadores j on j.id = c.jugador_id and j.rol = 'jugador'
                 where c.creado >= v_ini and c.creado < v_fin group by c.jugador_id, j.nombre order by count(*) desc limit 1)),
    'votantes', (select count(distinct votante_id) from public.votos where not es_publico and creado >= v_ini and creado < v_fin),
    'nuevos', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nombre', nombre, 'rol', rol) order by creado), '[]'::jsonb)
        from public.jugadores where rol = 'jugador' and creado >= v_ini and creado < v_fin),
    'jugaron', (select count(distinct m.jugador_id) from public.movimientos m join public.jugadores j on j.id = m.jugador_id and j.rol = 'jugador'
                 where m.concepto = 'Práctica del día' and m.creado >= v_ini and m.creado < v_fin),
    'rico', (select jsonb_build_object('id', id, 'nombre', nombre, 'billetes', billetes) from public.jugadores where rol = 'jugador' order by billetes desc, nombre limit 1),
    -- v20: por juego, solo el récord con que terminó el día y quién lo tenía antes
    'records', (select coalesce(jsonb_agg(x.r), '[]'::jsonb) from (
        select jsonb_build_object('juego', g.juego,
          'nuevo', (select jsonb_build_object('id', s.jugador_id, 'nombre', j.nombre, 'puntos', (s.dato->>'puntos')::int)
                      from public.sucesos s join public.jugadores j on j.id = s.jugador_id
                     where s.tipo = 'record' and s.dato->>'juego' = g.juego and s.creado >= v_ini and s.creado < v_fin order by s.id desc limit 1),
          'antes', (select jsonb_build_object('id', s.jugador_id, 'nombre', j.nombre, 'puntos', (s.dato->>'puntos')::int)
                      from public.sucesos s join public.jugadores j on j.id = s.jugador_id
                     where s.tipo = 'record' and s.dato->>'juego' = g.juego and s.creado < v_ini order by s.id desc limit 1),
          'actual', (select jsonb_build_object('id', p.jugador_id, 'nombre', j.nombre, 'puntos', p.mejor)
                       from public.practicas p join public.jugadores j on j.id = p.jugador_id and j.rol = 'jugador'
                      where p.juego = g.juego and p.mejor > 0 order by p.mejor desc limit 1)) as r
          from (values (1, 'monster2'), (3, 'memoria'), (4, 'adeudo')) g(o, juego) order by g.o) x   -- v26: sin Monster Crazy clásico (ya se retiró)
        where x.r->'actual' <> 'null'::jsonb),
    -- v24: duelos del día (solo los que alguien ganó)
    'duelos', jsonb_build_object(
        'n', (select count(*) from public.duelos where estado = 'terminado' and ganador is not null and fin >= v_ini and fin < v_fin),
        'mayor', (select jsonb_build_object('g', d.ganador, 'gn', jg.nombre, 'p', jp.id, 'pn', jp.nombre, 'juego', d.juego, 'apuesta', d.apuesta)
                    from public.duelos d join public.jugadores jg on jg.id = d.ganador
                    join public.jugadores jp on jp.id = case when d.ganador = d.reta then d.retado else d.reta end
                   where d.estado = 'terminado' and d.fin >= v_ini and d.fin < v_fin order by d.apuesta desc, d.fin desc limit 1),
        'rey', (select jsonb_build_object('id', j.id, 'nombre', j.nombre, 'n', count(*))
                  from public.duelos d join public.jugadores j on j.id = d.ganador
                 where d.estado = 'terminado' and d.fin >= v_ini and d.fin < v_fin
                 group by j.id, j.nombre having count(*) >= 2 order by count(*) desc, j.nombre limit 1)),
    'nota', (select texto from public.noticiero_notas where dia = v_dia),
    'nota_guion', (select guion from public.noticiero_notas where dia = v_dia)
  );
end $$;

-- Un habitante le cuenta una noticia al reportero (la producción ve quién la mandó)
create or replace function public.contar_reportero(p_token uuid, p_texto text)
returns void language plpgsql security definer set search_path = public as $$
declare
  yo public.jugadores;
  v text := regexp_replace(btrim(coalesce(p_texto, '')), '\s+', ' ', 'g');
begin
  yo := public._yo(p_token);
  if yo.rol <> 'jugador' then raise exception 'SOLO_HABITANTES'; end if;
  if char_length(v) < 3 or char_length(v) > 500 then raise exception 'NOTICIA_INVALIDA'; end if;
  if (select count(*) from public.reportajes where jugador_id = yo.id and creado > now() - interval '1 day') >= 10 then raise exception 'REPORTERO_LLENO'; end if;
  insert into public.reportajes (jugador_id, texto) values (yo.id, v);
  perform public._avisar_produccion('🎤 Noticia para el reportero', format('%s le contó algo al reportero. Revísalo en el panel (pestaña Noticiero).', yo.nombre));
end $$;

-- A las 9 de la mañana avisa a todos que ya salió la edición (una vez al día)
create or replace function public._noticiero_aviso()
returns void language plpgsql security definer set search_path = public as $$
declare v_hoy date := public._hoy();
begin
  if extract(hour from now() at time zone 'America/Mexico_City') <> 9 then return; end if;
  if (select noticiero_aviso from public.config where id = 1) is not distinct from v_hoy then return; end if;
  update public.config set noticiero_aviso = v_hoy where id = 1;
  if (select semana from public.config where id = 1) = 0 then return; end if;
  perform public._avisar('📺 ¡Ya salió El Noticierazo!', 'Elber Galarga y Rosa Melano te cuentan lo que pasó ayer en la casa. 🎙️');
end $$;
revoke all on function public._noticiero_aviso() from public, anon, authenticated;

-- ---------------------------------------------------------------------
--  v24: DUELOS entre habitantes
--  Piedra, papel o tijeras · Inflar el globo · Cálculo rápido · El camino correcto
-- ---------------------------------------------------------------------
create or replace function public._duelo_nombre(p_juego text)
returns text language sql immutable as $$
  select case p_juego when 'ppt' then 'Piedra, papel o tijeras' when 'globo' then 'Inflar el globo'
                      when 'calculo' then 'Cálculo rápido' else 'El camino correcto' end
$$;
-- Tiempo máximo de cada juego (después de eso se cierra solo)
create or replace function public._duelo_limite(p_juego text)
returns interval language sql immutable as $$
  select case p_juego when 'ppt' then interval '100 seconds' when 'globo' then interval '60 seconds'
                      when 'calculo' then interval '100 seconds' else interval '180 seconds' end
$$;

-- Cierra un duelo: el ganador se lleva lo de los dos; si empatan, a cada quien se le devuelve lo suyo
create or replace function public._terminar_duelo(p_id bigint, p_ganador uuid)
returns void language plpgsql security definer set search_path = public as $$
declare d public.duelos; v_jg text;
begin
  select * into d from public.duelos where id = p_id for update;
  if not found or d.estado <> 'jugando' then return; end if;
  update public.duelos set estado = 'terminado', fin = now(), ganador = p_ganador where id = d.id;
  v_jg := public._duelo_nombre(d.juego);
  if d.apuesta > 0 then
    if p_ganador is null then
      perform public._mover(d.reta, d.apuesta, 'Duelo empatado (' || v_jg || '): te devolvemos tu apuesta');
      perform public._mover(d.retado, d.apuesta, 'Duelo empatado (' || v_jg || '): te devolvemos tu apuesta');
    else
      perform public._mover(p_ganador, d.apuesta * 2, '¡Ganaste un duelo! (' || v_jg || ')');
    end if;
  end if;
end $$;

-- Retos que nadie contestó en 5 minutos y duelos que se quedaron a medias
create or replace function public._cerrar_duelos()
returns void language plpgsql security definer set search_path = public as $$
declare d public.duelos; v_g uuid; a int; b int;
begin
  update public.duelos set estado = 'caducado', fin = now() where estado = 'pendiente' and creado < now() - interval '5 minutes';
  for d in select * from public.duelos where estado = 'jugando' and inicio + public._duelo_limite(juego) + interval '10 seconds' < now()
           for update skip locked loop
    v_g := null;
    if d.juego = 'calculo' then             -- el único que entregó gana
      if d.res_a is not null and d.res_b is null then v_g := d.reta; elsif d.res_b is not null and d.res_a is null then v_g := d.retado; end if;
    elsif d.juego = 'ppt' then              -- gana quien iba ganando, o quien sí siguió jugando
      a := coalesce((d.datos->>'ga')::int, 0); b := coalesce((d.datos->>'gb')::int, 0);
      if a > b then v_g := d.reta; elsif b > a then v_g := d.retado;
      elsif d.datos->'pend' ? 'a' and not d.datos->'pend' ? 'b' then v_g := d.reta;
      elsif d.datos->'pend' ? 'b' and not d.datos->'pend' ? 'a' then v_g := d.retado; end if;
    elsif d.juego = 'camino' then           -- gana quien llegó más lejos
      a := coalesce((d.datos->>'fa')::int, 0); b := coalesce((d.datos->>'fb')::int, 0);
      if a > b then v_g := d.reta; elsif b > a then v_g := d.retado; end if;
    end if;                                 -- en el globo, si nadie lo reventó, empate
    perform public._terminar_duelo(d.id, v_g);
  end loop;
end $$;

-- Lo que ve cada quien de un duelo (sin las respuestas ni el camino mientras se juega)
create or replace function public._duelo_vista(p_id bigint, p_yo uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d public.duelos; v jsonb; k text; o text;
begin
  select * into d from public.duelos where id = p_id;
  if not found then return null; end if;
  k := case when p_yo = d.reta then 'a' else 'b' end; o := case when k = 'a' then 'b' else 'a' end;
  v := d.datos;
  if d.estado <> 'terminado' then
    if v ? 'ops' then v := jsonb_set(v, '{ops}', (select coalesce(jsonb_agg(op - 'r' order by i), '[]'::jsonb) from jsonb_array_elements(v->'ops') with ordinality x(op, i))); end if;
    v := v - 'camino';
    if v ? 'pend' then v := jsonb_set(v, '{pend}', (select coalesce(jsonb_object_agg(key, true), '{}'::jsonb) from jsonb_each(v->'pend'))); end if;
  end if;
  return jsonb_build_object('id', d.id, 'juego', d.juego, 'reta', d.reta, 'retado', d.retado, 'apuesta', d.apuesta, 'estado', d.estado,
    'datos', v, 'yo', k, 'ganador', d.ganador, 'creado', d.creado, 'inicio', d.inicio, 'fin', d.fin, 'ahora', now(),
    'res_yo', case when k = 'a' then d.res_a else d.res_b end,
    'res_otro', case when d.estado = 'terminado' then (case when o = 'a' then d.res_a else d.res_b end)
                     when (case when o = 'a' then d.res_a else d.res_b end) is not null then '{"listo":true}'::jsonb end);
end $$;

-- Para estado(): mi duelo pendiente o en juego, y el marcador de duelos de la temporada
create or replace function public._duelos_estado(p_yo uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'duelo', (select jsonb_build_object('id', d.id, 'juego', d.juego, 'reta', d.reta, 'retado', d.retado, 'apuesta', d.apuesta,
                'estado', d.estado, 'creado', d.creado, 'inicio', d.inicio, 'ahora', now())
                from public.duelos d where p_yo in (d.reta, d.retado) and d.estado in ('pendiente', 'jugando') order by d.id desc limit 1),
    'duelos_marcador', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'g', x.g, 'p', x.p) order by x.g desc, x.p), '[]'::jsonb) from (
        select j.id, count(*) filter (where d.ganador = j.id) as g, count(*) filter (where d.ganador is not null and d.ganador <> j.id) as p
          from public.jugadores j join public.duelos d on j.id in (d.reta, d.retado) and d.estado = 'terminado'
         where j.rol = 'jugador' group by j.id) x where x.g + x.p > 0))
$$;

-- Desafiar a otro habitante (aunque esté eliminado)
create or replace function public.retar_duelo(p_token uuid, p_rival uuid, p_juego text, p_apuesta int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare yo public.jugadores; r public.jugadores; v_id bigint;
begin
  yo := public._yo(p_token);
  if yo.rol <> 'jugador' then raise exception 'DUELO_SOLO_HABITANTES'; end if;
  select * into r from public.jugadores where id = p_rival;
  if not found or r.rol <> 'jugador' or r.id = yo.id then raise exception 'DUELO_RIVAL_INVALIDO'; end if;
  if p_juego is null or p_juego not in ('ppt', 'globo', 'calculo', 'camino') then raise exception 'OPCION_INVALIDA'; end if;
  if p_apuesta is null or p_apuesta < 0 or p_apuesta > 5000 then raise exception 'DUELO_APUESTA'; end if;
  if p_apuesta > yo.billetes then raise exception 'SIN_BILLETES'; end if;
  perform public._cerrar_duelos();
  if exists (select 1 from public.duelos where estado in ('pendiente', 'jugando') and yo.id in (reta, retado)) then raise exception 'DUELO_YA_TIENES'; end if;
  if exists (select 1 from public.duelos where estado in ('pendiente', 'jugando') and r.id in (reta, retado)) then raise exception 'DUELO_RIVAL_OCUPADO'; end if;
  if exists (select 1 from public.duelos where reta = yo.id and retado = r.id and estado = 'rechazado' and fin > now() - interval '1 minute') then
    raise exception 'DUELO_ESPERA';
  end if;
  insert into public.duelos (juego, reta, retado, apuesta) values (p_juego, yo.id, r.id, p_apuesta) returning id into v_id;
  perform public._avisar('⚔️ ¡Te retaron a un duelo!', format('%s te reta a %s%s. Tienes 5 minutos para aceptar.', yo.nombre,
    public._duelo_nombre(p_juego), case when p_apuesta > 0 then format(' por $%s', p_apuesta) else '' end), array[r.id]);
  return public._duelo_vista(v_id, yo.id);
end $$;

-- Quien retó se arrepiente antes de que le contesten
create or replace function public.cancelar_duelo(p_token uuid, p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare yo public.jugadores;
begin
  yo := public._yo(p_token);
  update public.duelos set estado = 'cancelado', fin = now() where id = p_id and reta = yo.id and estado = 'pendiente';
end $$;

-- El retado acepta (se cobra la apuesta a los dos y arranca en 5 segundos) o rechaza
create or replace function public.responder_duelo(p_token uuid, p_id bigint, p_ok boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  yo public.jugadores;
  d public.duelos;
  v_reta text;
  v_datos jsonb;
  v_ops jsonb := '[]'::jsonb;
  i int; t int; a int; b int;
begin
  yo := public._yo(p_token);
  perform public._cerrar_duelos();
  select * into d from public.duelos where id = p_id for update;
  if not found or d.retado <> yo.id then raise exception 'DUELO_NO_EXISTE'; end if;
  if d.estado <> 'pendiente' then return jsonb_build_object('error', 'DUELO_YA_NO'); end if;   -- sin excepción: así se guarda que caducó
  v_reta := (select nombre from public.jugadores where id = d.reta);
  if not coalesce(p_ok, false) then
    update public.duelos set estado = 'rechazado', fin = now() where id = d.id;
    perform public._avisar('⚔️ Duelo rechazado', format('%s no aceptó tu duelo de %s.', yo.nombre, public._duelo_nombre(d.juego)), array[d.reta]);
    return public._duelo_vista(d.id, yo.id);
  end if;
  if yo.billetes < d.apuesta then raise exception 'SIN_BILLETES'; end if;
  if (select billetes from public.jugadores where id = d.reta) < d.apuesta then
    update public.duelos set estado = 'cancelado', fin = now() where id = d.id;
    return jsonb_build_object('error', 'DUELO_RIVAL_SIN_BILLETES');
  end if;
  perform public._mover(d.reta, -d.apuesta, format('Apuesta de duelo contra %s (%s)', yo.nombre, public._duelo_nombre(d.juego)));
  perform public._mover(yo.id, -d.apuesta, format('Apuesta de duelo contra %s (%s)', v_reta, public._duelo_nombre(d.juego)));
  if d.juego = 'calculo' then
    for i in 1..10 loop
      t := floor(random() * 4);
      if t = 0 then a := 10 + floor(random() * 90); b := 10 + floor(random() * 90); v_ops := v_ops || jsonb_build_object('t', a || ' + ' || b, 'r', a + b);
      elsif t = 1 then a := 20 + floor(random() * 80); b := 1 + floor(random() * (a - 1)); v_ops := v_ops || jsonb_build_object('t', a || ' − ' || b, 'r', a - b);
      elsif t = 2 then a := 2 + floor(random() * 11); b := 2 + floor(random() * 11); v_ops := v_ops || jsonb_build_object('t', a || ' × ' || b, 'r', a * b);
      else b := 2 + floor(random() * 11); a := b * (2 + floor(random() * 11)); v_ops := v_ops || jsonb_build_object('t', a || ' ÷ ' || b, 'r', a / b);
      end if;
    end loop;
    v_datos := jsonb_build_object('ops', v_ops);
  elsif d.juego = 'camino' then
    v_datos := jsonb_build_object('camino', (select jsonb_agg(floor(random() * 2)::int) from generate_series(1, 5)), 'fa', 0, 'fb', 0, 'ca', 0, 'cb', 0);
  elsif d.juego = 'globo' then
    v_datos := jsonb_build_object('taps', 40);
  else
    v_datos := jsonb_build_object('rondas', '[]'::jsonb, 'ga', 0, 'gb', 0, 'pend', '{}'::jsonb);
  end if;
  update public.duelos set estado = 'jugando', inicio = now() + interval '5 seconds', datos = v_datos where id = d.id;
  perform public._avisar('⚔️ ¡Aceptaron tu duelo!', format('%s aceptó tu reto de %s. ¡Entra ya, que ya empieza!', yo.nombre, public._duelo_nombre(d.juego)), array[d.reta]);
  return public._duelo_vista(d.id, yo.id);
end $$;

-- Ver cómo va un duelo
create or replace function public.ver_duelo(p_token uuid, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare yo public.jugadores;
begin
  yo := public._yo(p_token);
  perform public._cerrar_duelos();
  if not exists (select 1 from public.duelos where id = p_id and yo.id in (reta, retado)) then raise exception 'DUELO_NO_EXISTE'; end if;
  return public._duelo_vista(p_id, yo.id);
end $$;

-- Una jugada dentro del duelo
--   ppt:     {"ronda": n, "mano": 0 piedra | 1 papel | 2 tijeras}
--   globo:   {"fin": true}               (ya lo reventé)
--   calculo: {"resp": [10 números]}      (mis respuestas)
--   camino:  {"fase": n, "lado": 0 izquierda | 1 derecha}
--   todos:   {"rendir": true}
create or replace function public.jugada_duelo(p_token uuid, p_id bigint, p_dato jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  yo public.jugadores;
  d public.duelos;
  k text; o text;
  n int; m int; ma int; mb int; ga int; gb int;
  v jsonb; w text;
begin
  yo := public._yo(p_token);
  select * into d from public.duelos where id = p_id for update;
  if not found or yo.id not in (d.reta, d.retado) then raise exception 'DUELO_NO_EXISTE'; end if;
  k := case when yo.id = d.reta then 'a' else 'b' end; o := case when k = 'a' then 'b' else 'a' end;
  if d.estado <> 'jugando' or now() < d.inicio then return public._duelo_vista(d.id, yo.id); end if;
  if coalesce((p_dato->>'rendir')::boolean, false) then
    update public.duelos set datos = datos || jsonb_build_object('rindio', k) where id = d.id;
    perform public._terminar_duelo(d.id, case when k = 'a' then d.retado else d.reta end);
    return public._duelo_vista(d.id, yo.id);
  end if;

  if d.juego = 'globo' then
    if coalesce((p_dato->>'fin')::boolean, false) and now() >= d.inicio + interval '2 seconds' then
      perform public._terminar_duelo(d.id, yo.id);
    end if;

  elsif d.juego = 'calculo' then
    if (case when k = 'a' then d.res_a else d.res_b end) is null then
      select count(*) into n from jsonb_array_elements(d.datos->'ops') with ordinality x(op, i)
       where (p_dato->'resp'->>(i::int - 1)) is not null and (p_dato->'resp'->>(i::int - 1)) = (op->>'r');
      v := jsonb_build_object('ok', n, 'ms', floor(extract(epoch from now() - d.inicio) * 1000)::int,
                              'resp', coalesce(p_dato->'resp', '[]'::jsonb));
      if k = 'a' then update public.duelos set res_a = v where id = d.id; d.res_a := v;
      else update public.duelos set res_b = v where id = d.id; d.res_b := v; end if;
      if d.res_a is not null and d.res_b is not null then
        ma := (d.res_a->>'ok')::int; mb := (d.res_b->>'ok')::int;
        perform public._terminar_duelo(d.id, case
          when ma > mb then d.reta when mb > ma then d.retado
          when (d.res_a->>'ms')::int < (d.res_b->>'ms')::int then d.reta
          when (d.res_b->>'ms')::int < (d.res_a->>'ms')::int then d.retado end);
      end if;
    end if;

  elsif d.juego = 'camino' then
    if now() < coalesce((d.datos->>('bloq' || k))::timestamptz, '-infinity'::timestamptz) then return public._duelo_vista(d.id, yo.id); end if;
    n := coalesce((d.datos->>('f' || k))::int, 0);
    if (p_dato->>'fase')::int is distinct from n then return public._duelo_vista(d.id, yo.id); end if;
    if (p_dato->>'lado')::int = (d.datos->'camino'->>n)::int then
      d.datos := d.datos || jsonb_build_object('f' || k, n + 1, 'ult' || k, 'ok');
      update public.duelos set datos = d.datos where id = d.id;
      if n + 1 >= 5 then perform public._terminar_duelo(d.id, yo.id); end if;
    else            -- se cayó: regresa a la fase 1 y espera 4 segundos
      d.datos := d.datos || jsonb_build_object('f' || k, 0, 'ult' || k, 'cae', 'bloq' || k, now() + interval '4 seconds',
                                               'c' || k, coalesce((d.datos->>('c' || k))::int, 0) + 1);
      update public.duelos set datos = d.datos where id = d.id;
    end if;

  elsif d.juego = 'ppt' then
    n := jsonb_array_length(d.datos->'rondas');
    m := (p_dato->>'mano')::int;
    if (p_dato->>'ronda')::int is distinct from n or m is null or m not between 0 and 2 or d.datos->'pend' ? k then
      return public._duelo_vista(d.id, yo.id);
    end if;
    v := d.datos->'pend' || jsonb_build_object(k, m);
    if v ? 'a' and v ? 'b' then
      ma := (v->>'a')::int; mb := (v->>'b')::int;
      w := case when ma = mb then '' when (ma - mb + 3) % 3 = 1 then 'a' else 'b' end;    -- papel le gana a piedra, etc.
      ga := (d.datos->>'ga')::int + case when w = 'a' then 1 else 0 end;
      gb := (d.datos->>'gb')::int + case when w = 'b' then 1 else 0 end;
      d.datos := d.datos || jsonb_build_object('rondas', d.datos->'rondas' || jsonb_build_array(jsonb_build_object('a', ma, 'b', mb, 'g', w)),
                                               'ga', ga, 'gb', gb, 'pend', '{}'::jsonb);
      update public.duelos set datos = d.datos where id = d.id;
      if ga >= 2 then perform public._terminar_duelo(d.id, d.reta);
      elsif gb >= 2 then perform public._terminar_duelo(d.id, d.retado);
      elsif n + 1 >= 9 then perform public._terminar_duelo(d.id, case when ga > gb then d.reta when gb > ga then d.retado end);
      end if;
    else
      update public.duelos set datos = jsonb_set(d.datos, '{pend}', v) where id = d.id;
    end if;
  end if;
  return public._duelo_vista(d.id, yo.id);
end $$;
revoke all on function public._terminar_duelo(bigint, uuid) from public, anon, authenticated;
revoke all on function public._cerrar_duelos() from public, anon, authenticated;
revoke all on function public._duelo_vista(bigint, uuid) from public, anon, authenticated;
revoke all on function public._duelos_estado(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
--  v27: LA PASARELA (Ricky Reflector)
-- ---------------------------------------------------------------------
-- Resumen de la semana para el inicio de la pasarela
create or replace function public._resumen_semana(p_semana int)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_ini timestamptz; c public.config;
begin
  select * into c from public.config where id = 1;
  select creado into v_ini from public.sucesos where tipo = 'semana' and (dato->>'semana')::int = p_semana order by id desc limit 1;
  v_ini := coalesce(v_ini, now() - interval '7 days');
  return jsonb_build_object(
    'prueba', c.prueba,
    'lider', (select nombre from public.jugadores where id = c.lider_id),
    'misiones', jsonb_build_object(
      'n', (select count(*) from public.movimientos where concepto = 'Misión secreta cumplida' and creado >= v_ini),
      'top', (select jsonb_build_object('nombre', j.nombre, 'n', count(*)) from public.movimientos m join public.jugadores j on j.id = m.jugador_id
               where m.concepto = 'Misión secreta cumplida' and m.creado >= v_ini group by j.nombre order by count(*) desc, j.nombre limit 1)),
    'duelos', jsonb_build_object(
      'n', (select count(*) from public.duelos where estado = 'terminado' and ganador is not null and fin >= v_ini),
      'top', (select jsonb_build_object('nombre', j.nombre, 'n', count(*)) from public.duelos d join public.jugadores j on j.id = d.ganador
               where d.estado = 'terminado' and d.fin >= v_ini group by j.nombre order by count(*) desc, j.nombre limit 1)),
    'records', (select coalesce(jsonb_agg(jsonb_build_object('juego', x.juego, 'nombre', x.nombre, 'puntos', x.puntos)), '[]'::jsonb) from (
        select distinct on (s.dato->>'juego') s.dato->>'juego' as juego, j.nombre, (s.dato->>'puntos')::int as puntos
          from public.sucesos s join public.jugadores j on j.id = s.jugador_id
         where s.tipo = 'record' and s.creado >= v_ini and s.dato->>'juego' <> 'monster'
         order by s.dato->>'juego', s.id desc) x),
    'rico', (select jsonb_build_object('nombre', nombre, 'billetes', billetes) from public.jugadores where rol = 'jugador' order by billetes desc, nombre limit 1));
end $$;

-- Cierra un empate de la pasarela: lo decidió el líder, la producción o la suerte
create or replace function public._resolver_empate(p_id uuid, p_como text)
returns uuid language plpgsql security definer set search_path = public as $$
declare c public.config; v uuid;
begin
  select * into c from public.config where id = 1 for update;
  if c.fase <> 'gala' or c.eliminado_id is not null or c.es_final or cardinality(c.empatados) < 2 or not c.gala_revelada then return null; end if;
  v := coalesce(p_id, c.empatados[1 + floor(random() * cardinality(c.empatados))::int]);
  if not (v = any (c.empatados)) then raise exception 'NO_EMPATADO'; end if;
  update public.config set eliminado_id = v, llamada_hasta = least(coalesce(llamada_hasta, now()), now()), actualizado = now() where id = 1;
  update public.historial set resultados = resultados || jsonb_build_object('eliminado_id', v,
           'eliminado', (select nombre from public.jugadores where id = v), 'empate_pendiente', false,
           'decidio', case when p_id is null then 'azar' else p_como end)
   where semana = c.semana;
  update public.jugadores set estado = 'eliminado', semana_eliminado = c.semana where id = v;
  perform public._liquidar('eliminado', c.semana, array[v::text], format('eliminado de la semana %s', c.semana));
  return v;
end $$;

-- Si el líder no contestó en sus 50 segundos (o nadie vio la pasarela en 30 minutos), decide la suerte
create or replace function public._empate_vencido()
returns void language plpgsql security definer set search_path = public as $$
declare c public.config;
begin
  select * into c from public.config where id = 1;
  if c.fase <> 'gala' or not c.gala_revelada or c.eliminado_id is not null or c.es_final or cardinality(c.empatados) < 2 then return; end if;
  if (c.llamada_hasta is not null and now() > c.llamada_hasta + interval '4 seconds')
     or (c.llamada_ini is null and (select creado from public.historial where semana = c.semana) < now() - interval '30 minutes') then
    perform public._resolver_empate(null, 'azar');
  end if;
end $$;

-- Ricky Reflector toma el teléfono: el primer celular que llega a ese momento de la pasarela hace la llamada
create or replace function public.gala_llamar(p_token uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.config;
begin
  perform public._yo(p_token);
  perform public._empate_vencido();
  select * into c from public.config where id = 1 for update;
  if c.fase = 'gala' and c.gala_revelada and c.eliminado_id is null and not c.es_final and cardinality(c.empatados) > 1 and c.llamada_ini is null then
    if c.lider_id is null then
      perform public._resolver_empate(null, 'azar');
    else
      update public.config set llamada_ini = now(), llamada_hasta = now() + interval '50 seconds' where id = 1;
      perform public._avisar('📞 ¡Ricky Reflector te está llamando!', 'Hubo empate en la pasarela. Eres el líder: tienes 50 segundos para decidir quién sale. ¡Entra ya!', array[c.lider_id]);
      perform public._avisar_produccion('📞 Empate en la pasarela', 'El líder tiene 50 segundos para decidir. Si no contesta, decide la suerte.');
    end if;
  end if;
  select * into c from public.config where id = 1;
  return jsonb_build_object('ahora', now(), 'llamada_hasta', c.llamada_hasta, 'eliminado_id', c.eliminado_id, 'lider_id', c.lider_id);
end $$;
revoke all on function public._resumen_semana(int) from public, anon, authenticated;
revoke all on function public._resolver_empate(uuid, text) from public, anon, authenticated;
revoke all on function public._empate_vencido() from public, anon, authenticated;

-- v28: vista previa de la pasarela para la producción (no cambia nada: calcula lo que saldría con los votos de ahorita)
create or replace function public.admin_gala_avance()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  c public.config;
  res jsonb;
  v_max int;
  v_emp uuid[];
  v_max_lider int;
  v_max_otros int;
begin
  perform public._solo_admin();
  select * into c from public.config where id = 1;
  if c.semana = 0 then raise exception 'SIN_SEMANA'; end if;
  res := public._resultados(c.semana);
  if c.es_final then
    return jsonb_build_object('semana', c.semana, 'final', true, 'avance', true, 'eliminado_id', null, 'lider_id', null,
      'podio', (select jsonb_agg(jsonb_build_object('id', x->>'id', 'nombre', x->>'nombre', 'puntos', (x->>'puntos')::int, 'lugar', lugar) order by lugar, x->>'nombre')
                  from (select x, dense_rank() over (order by (x->>'puntos')::int) as lugar from jsonb_array_elements(res) x) t),
      'tabla', res);
  end if;
  select max((x->>'puntos')::int) into v_max from jsonb_array_elements(res) x where (x->>'id')::uuid is distinct from c.lider_id;
  select array_agg((x->>'id')::uuid) into v_emp from jsonb_array_elements(res) x
   where (x->>'id')::uuid is distinct from c.lider_id and (x->>'puntos')::int = v_max;
  select max((x->>'puntos')::int) filter (where (x->>'id')::uuid = c.lider_id),
         max((x->>'puntos')::int) filter (where (x->>'id')::uuid is distinct from c.lider_id)
    into v_max_lider, v_max_otros from jsonb_array_elements(res) x;
  return jsonb_build_object(
    'semana', c.semana, 'avance', true,
    'eliminado_id', case when cardinality(v_emp) = 1 then v_emp[1] end,
    'eliminado', case when cardinality(v_emp) = 1 then (select nombre from public.jugadores where id = v_emp[1]) end,
    'lider_id', c.lider_id,
    'lider', (select nombre from public.jugadores where id = c.lider_id),
    'lider_salvado', coalesce(v_max_lider > 0 and v_max_lider >= v_max_otros, false),
    'desempate', coalesce(cardinality(v_emp), 0) > 1,
    'empatados', case when cardinality(v_emp) > 1 then to_jsonb(v_emp) else '[]'::jsonb end,
    'empate_pendiente', coalesce(cardinality(v_emp), 0) > 1,
    'resumen', public._resumen_semana(c.semana),
    'tabla', res);
end $$;

-- Las funciones internas no se pueden llamar directo desde el celular
revoke all on function public._iniciar_semana(text)  from public, anon, authenticated;
revoke all on function public._cerrar_prueba(uuid)   from public, anon, authenticated;
revoke all on function public._cerrar_votacion()     from public, anon, authenticated;
revoke all on function public._revelar()             from public, anon, authenticated;
revoke all on function public._avanzar_agenda()      from public, anon, authenticated;
revoke all on function public._avisar(text, text, uuid[]) from public, anon, authenticated;
revoke all on function public._recordatorios()       from public, anon, authenticated;
revoke all on function public._avisar_produccion(text, text) from public, anon, authenticated;
revoke all on function public._reloj()               from public, anon, authenticated;
revoke all on function public._mover(uuid, int, text) from public, anon, authenticated;
revoke all on function public._liquidar(text, bigint, text[], text) from public, anon, authenticated;
revoke all on function public._encuestas()           from public, anon, authenticated;
revoke all on function public._repartir_misiones(int, boolean) from public, anon, authenticated;
revoke all on function public._economia(uuid, int)   from public, anon, authenticated;

-- Que Supabase reconozca de inmediato las funciones nuevas
notify pgrst, 'reload schema';
