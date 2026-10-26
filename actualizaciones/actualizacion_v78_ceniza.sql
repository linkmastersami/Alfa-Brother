-- v78: Ciudad Ceniza (arcade de zombies) como práctica con récords y Billetes, y como prueba del líder.
-- Cópialo todo en Supabase → SQL Editor → New query → Run. No borra datos.
alter table public.practicas drop constraint if exists practicas_juego_check;
alter table public.practicas add constraint practicas_juego_check check (juego in ('memoria','adeudo','monster','monster2','billetes','cobranza','ritmo','super','rompe','ceniza'));
alter table public.config drop constraint if exists config_prueba_check;
alter table public.config add constraint config_prueba_check check (prueba in ('trivia','memoria','adeudo','billetes','monster2','cobranza','ritmo','super','rompe','ceniza'));

create or replace function public.enviar_puntaje(p_token uuid, p_puntaje int)
returns int language plpgsql security definer set search_path = public as $$
declare
  yo public.jugadores;
  c public.config;
  v int;
begin
  yo := public._yo(p_token);
  select * into c from public.config where id = 1;
  if c.fase <> 'prueba' or c.prueba = 'trivia' then raise exception 'PRUEBA_CERRADA'; end if;
  -- v77: cada juego tiene su tope de puntos
  v := least(greatest(coalesce(p_puntaje, 0), 0), case c.prueba when 'monster2' then 5000000 when 'cobranza' then 2000000 when 'rompe' then 2000000 when 'ceniza' then 5000000
                                                         when 'super' then 500000 when 'ritmo' then 200000 else 20000 end);
  update public.intentos set puntaje = v, terminado = now()
   where semana = c.semana and jugador_id = yo.id and terminado is null;
  if not found then raise exception 'SIN_INTENTO'; end if;
  return v;
end $$;

create or replace function public._nombre_prueba(p text)
returns text language sql immutable as $$
  select case p when 'trivia' then 'Trivia de la oficina' when 'memoria' then 'Memoria de expedientes'
                when 'adeudo' then 'Calcula el adeudo' when 'billetes' then 'Cuenta los billetes verdes'
                when 'monster2' then 'Monster Crazy 2.0' when 'cobranza' then 'Cobranza furiosa' when 'ritmo' then 'Sigue el ritmo'
                when 'super' then 'Súper Cobrador' when 'rompe' then 'Rompe Deudas' when 'ceniza' then 'Ciudad Ceniza' else 'la prueba' end
$$;

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
    if p_prueba not in ('trivia','memoria','adeudo','billetes','monster2','cobranza','ritmo','super','rompe','ceniza') then raise exception 'PRUEBA_INVALIDA'; end if;
    if p_prueba = 'trivia' and not exists (select 1 from public.trivia where activa) then raise exception 'SIN_TRIVIAS'; end if;
  end if;
  update public.config
     set semana = c.semana + 1,
         fase = case when not v_final then 'prueba'
                     when c.ag_semana = c.semana + 1 and c.ag_voto_ini > now() then 'espera'
                     else 'votacion' end,
         prueba = case when v_final then null else p_prueba end,
         es_final = v_final, lider_id = case when v_final then null else c.lider_id end, eliminado_id = null,
         prueba_abre = case when not v_final and c.ag_semana = c.semana + 1 and c.ag_prueba_abre > now() then c.ag_prueba_abre end,   -- v43: el líder sigue hasta que se nombra el siguiente
         empatados = '{}', gala_revelada = false, actualizado = now()
   where id = 1;
  insert into public.sucesos (tipo, dato) values ('semana', jsonb_build_object('semana', c.semana + 1, 'prueba', case when v_final then null else p_prueba end, 'final', v_final));
  update public.practicas set mejor = 0 where mejor <> 0;     -- v40: los récords vuelven a cero cada semana
  -- misiones secretas de la semana nueva
  begin perform public._repartir_misiones(c.semana + 1, false);
  exception when others then null; end;
end $$;

create or replace function public._stats_lider(p_semana int)
returns table (jugador_id uuid, misiones int, jugadas int, duelos_g int, rec numeric)
language sql stable security definer set search_path = public as $$
  with v as (select public._ini_semana(p_semana) as ini),     -- v43: solo lo de esta semana (desde que empezó hasta que cierra la prueba)
  pa as (select p.jugador_id, p.juego, count(*) as n, max(p.puntaje) as mejor
           from public.partidas p, v where p.creado >= v.ini and p.juego <> 'duelo' group by 1, 2),
  tops as (select pa.juego, max(pa.mejor) as top from pa join public.jugadores jj on jj.id = pa.jugador_id and jj.rol = 'jugador'
            where pa.juego in ('monster2', 'memoria', 'adeudo', 'billetes', 'cobranza', 'ritmo', 'super', 'rompe', 'ceniza') group by pa.juego having max(pa.mejor) > 0)
  select j.id,
    least(5, (select count(*) from public.misiones m where m.semana = p_semana and m.jugador_id = j.id and m.cumplida is not null))::int,
    ((select coalesce(sum(pa.n), 0) from pa where pa.jugador_id = j.id)
      + (select count(*) from public.duelos d, v where d.estado = 'terminado' and j.id in (d.reta, d.retado) and d.fin >= v.ini))::int,
    (select count(*) from public.duelos d, v where d.estado = 'terminado' and d.ganador = j.id and d.fin >= v.ini)::int,
    round(coalesce((select sum(least(1, pa.mejor::numeric / t.top)) from pa join tops t on t.juego = pa.juego where pa.jugador_id = j.id)
                   / nullif((select count(*) from tops), 0), 0), 3)
  from public.jugadores j where j.rol = 'jugador' and j.estado = 'activo'
$$;

create or replace function public.admin_set_agenda(p jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._solo_admin();
  if p is null then
    update public.config set ag_semana = null, ag_prueba = null, ag_prueba_ini = null, ag_prueba_fin = null, ag_prueba_abre = null,
           ag_voto_ini = null, ag_voto_fin = null, ag_gala = null, actualizado = now() where id = 1;
    return;
  end if;
  if coalesce(p->>'prueba', 'memoria') not in ('trivia','memoria','adeudo','billetes','monster2','cobranza','ritmo','super','rompe','ceniza') then raise exception 'PRUEBA_INVALIDA'; end if;
  update public.config
     set ag_semana     = (p->>'semana')::int,
         ag_prueba     = coalesce(p->>'prueba', 'memoria'),
         ag_prueba_ini = nullif(p->>'prueba_ini', '')::timestamptz,
         ag_prueba_fin = nullif(p->>'prueba_fin', '')::timestamptz,
         ag_prueba_abre = nullif(p->>'prueba_abre', '')::timestamptz,
         ag_voto_ini   = nullif(p->>'voto_ini', '')::timestamptz,
         ag_voto_fin   = nullif(p->>'voto_fin', '')::timestamptz,
         ag_gala       = nullif(p->>'gala', '')::timestamptz,
         ag_repetir    = coalesce((p->>'repetir')::boolean, true),
         actualizado   = now()
   where id = 1;
end $$;

create or replace function public.admin_cambiar_prueba(p_prueba text)
returns int language plpgsql security definer set search_path = public as $$
declare c public.config; v_n int; v_nom text;
begin
  perform public._solo_admin();
  select * into c from public.config where id = 1 for update;
  if c.fase <> 'prueba' then raise exception 'FASE_INCORRECTA'; end if;
  if p_prueba not in ('trivia','memoria','adeudo','billetes','monster2','cobranza','ritmo','super','rompe','ceniza') then raise exception 'PRUEBA_INVALIDA'; end if;
  if p_prueba = 'trivia' and not exists (select 1 from public.trivia where activa) then raise exception 'SIN_TRIVIAS'; end if;
  delete from public.intentos where semana = c.semana;
  get diagnostics v_n = row_count;
  update public.config set prueba = p_prueba, actualizado = now() where id = 1;
  v_nom := public._nombre_prueba(p_prueba);
  if c.prueba_abre is null or c.prueba_abre <= now() then
    perform public._avisar('🔄 Cambió la prueba del líder', format('Ahora la prueba es %s. Si ya habías jugado, vuelve a jugar: se reinició para todos.', v_nom));
  end if;
  return v_n;
end $$;

create or replace function public._pago_jugar(p_yo uuid, p_juego text, p_puntaje int, p_fijo int default null)
returns int language plpgsql security definer set search_path = public as $$
declare v int; v_ref numeric; v_hoy int;
begin
  v_ref := case p_juego when 'memoria' then 713 when 'adeudo' then 1450 when 'billetes' then 500 when 'cobranza' then 60000 when 'ritmo' then 7000 when 'super' then 25000 when 'rompe' then 20000 when 'ceniza' then 120000 else 54228 end;   -- v60: Cobranza furiosa · v66: Sigue el ritmo
  v := coalesce(p_fijo, round(50 * least(1, greatest(coalesce(p_puntaje, 0), 0) / v_ref))::int);
  select coalesce(sum(pago), 0) into v_hoy from public.partidas
   where jugador_id = p_yo and creado >= (public._hoy()::timestamp at time zone 'America/Mexico_City');
  v := greatest(0, least(v, 2000 - v_hoy));
  insert into public.partidas (jugador_id, juego, puntaje, pago) values (p_yo, p_juego, greatest(coalesce(p_puntaje, 0), 0), v);
  if v > 0 then
    perform public._mover(p_yo, v, case when p_juego = 'duelo' then 'Jugaste un duelo' else 'Jugaste una partida' end);
  end if;
  return v;
end $$;

create or replace function public.guardar_practica(p_token uuid, p_juego text, p_puntaje int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  yo public.jugadores;
  v int;
  v_rec int;
  p public.practicas;
  v_pago int := 0;
  v_record boolean := false;
begin
  yo := public._yo(p_token);
  if p_juego not in ('memoria', 'adeudo', 'monster', 'monster2', 'billetes', 'cobranza', 'ritmo', 'super', 'rompe', 'ceniza') then raise exception 'JUEGO_INVALIDO'; end if;   -- v75: Súper Cobrador y Rompe Deudas
  v := least(greatest(coalesce(p_puntaje, 0), 0), case p_juego when 'memoria' then 1000 when 'billetes' then 20000 when 'adeudo' then 20000 else 5000000 end);
  select coalesce(max(p2.mejor), 0) into v_rec from public.practicas p2 join public.jugadores j on j.id = p2.jugador_id and j.rol = 'jugador' where p2.juego = p_juego;
  insert into public.practicas (jugador_id, juego) values (yo.id, p_juego) on conflict do nothing;
  select * into p from public.practicas where jugador_id = yo.id and juego = p_juego for update;
  v_pago := public._pago_jugar(yo.id, p_juego, v);
  if v > v_rec and v > 0 and yo.rol = 'jugador' then        -- el público guarda su mejor marca, pero no cuenta para los récords de la casa
    v_record := true;
    insert into public.sucesos (tipo, jugador_id, dato) values ('record', yo.id, jsonb_build_object('juego', p_juego, 'puntos', v, 'antes', v_rec));
  end if;
  update public.practicas
     set mejor = greatest(mejor, v), partidas = partidas + 1, ultimo_premio = public._hoy(),
         ultimo_record = case when v_record then public._hoy() else ultimo_record end
   where jugador_id = yo.id and juego = p_juego;
  return jsonb_build_object('mejor', greatest(p.mejor, v), 'record', v_record, 'premio', v_pago, 'pago', v_pago,
    'hoy', (select coalesce(sum(pago), 0) from public.partidas where jugador_id = yo.id and creado >= (public._hoy()::timestamp at time zone 'America/Mexico_City')),
    'top', (select coalesce(jsonb_agg(jsonb_build_object('id', t.jugador_id, 'nombre', j.nombre, 'mejor', t.mejor) order by t.mejor desc), '[]'::jsonb)
              from (select p3.* from public.practicas p3 join public.jugadores j3 on j3.id = p3.jugador_id and j3.rol = 'jugador'
                     where p3.juego = p_juego and p3.mejor > 0 order by p3.mejor desc limit 5) t
              join public.jugadores j on j.id = t.jugador_id));
end $$;

create or replace function public.noticiero(p_token uuid, p_avance boolean default false)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_dia date := public._noticiero_dia() + case when p_avance then 1 else 0 end;
  v_ini timestamptz := (v_dia::timestamp) at time zone 'America/Mexico_City';
  v_fin timestamptz := ((v_dia + 1)::timestamp) at time zone 'America/Mexico_City';
begin
  if public.es_admin() then null;                    -- la producción puede ver cualquiera
  elsif p_avance then raise exception 'NO_AUTORIZADO';
  else perform public._yo(p_token);
  end if;
  return jsonb_build_object(
    'dia', v_dia, 'avance', p_avance,
    'cambios', (select g.cambios from public.noticiero_guiones g where g.dia = v_dia),
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
    'jugaron', (select count(distinct p.jugador_id) from public.partidas p join public.jugadores j on j.id = p.jugador_id and j.rol = 'jugador'
                 where p.juego <> 'duelo' and p.creado >= v_ini and p.creado < v_fin),
    -- v43: el que más billetes generó en la semana
    'rico', (select jsonb_build_object('id', j.id, 'nombre', j.nombre, 'billetes', g.generado)
               from public._generado(public._ini_semana((select semana from public.config where id = 1))) g join public.jugadores j on j.id = g.jugador_id and j.rol = 'jugador'
              where g.generado > 0 order by g.generado desc, j.nombre limit 1),
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
          from (values (1, 'monster2'), (3, 'memoria'), (4, 'adeudo'), (5, 'billetes'), (6, 'cobranza'), (7, 'ritmo'), (8, 'super'), (9, 'rompe', 'ceniza')) g(o, juego) order by g.o) x   -- v26: sin Monster Crazy clásico (ya se retiró)
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
