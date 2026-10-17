-- ALFA BROTHER · ACTUALIZACIÓN v43 · PARTE 2 de 2 (el que más generó en la semana, en noticias y pasarela)
-- Pégala en SQL Editor → Run.


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
          from (values (1, 'monster2'), (3, 'memoria'), (4, 'adeudo'), (5, 'billetes')) g(o, juego) order by g.o) x   -- v26: sin Monster Crazy clásico (ya se retiró)
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
    'rico', (select jsonb_build_object('nombre', j.nombre, 'billetes', g.generado)
               from public._generado(public._ini_semana(p_semana)) g join public.jugadores j on j.id = g.jugador_id and j.rol = 'jugador'
              where g.generado > 0 order by g.generado desc, j.nombre limit 1));
end $$;

notify pgrst, 'reload schema';
