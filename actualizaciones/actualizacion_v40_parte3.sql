-- ALFA BROTHER · ACTUALIZACIÓN v40 · PARTE 3 de 3
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
    'galas', (select coalesce(jsonb_agg(h.semana order by h.semana desc), '[]'::jsonb) from public.historial h),
    -- v40: cómo voy para ser líder (mientras está abierta la prueba)
    'mi_lider', case when c.fase = 'prueba' and yo.rol = 'jugador' and yo.estado = 'activo' then (
        select jsonb_build_object('misiones', s.misiones, 'jugadas', s.jugadas, 'duelos_g', s.duelos_g, 'rec', s.rec,
                 'max_jugadas', (select max(x.jugadas) from public._stats_lider(c.semana) x),
                 'max_duelos', (select max(x.duelos_g) from public._stats_lider(c.semana) x))
          from public._stats_lider(c.semana) s where s.jugador_id = yo.id) end,
    -- v34: habitantes que todavía no votan (solo mientras está abierta la votación; no dice por quién votó nadie)
    'sin_votar', case when c.fase = 'votacion' then (select coalesce(jsonb_agg(j.id order by j.nombre), '[]'::jsonb)
        from public.jugadores j where j.rol = 'jugador'
         and not exists (select 1 from public.votos v where v.semana = c.semana and v.votante_id = j.id)) end
  ) || public._economia(yo.id, v_bono) || public._duelos_estado(yo.id);
end $$;

notify pgrst, 'reload schema';
