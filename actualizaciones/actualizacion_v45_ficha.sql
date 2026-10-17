-- ALFA BROTHER · ACTUALIZACIÓN v45: la ficha por semana
-- Pégala en SQL Editor → Run.

create or replace function public.ficha_semana(p_token uuid, p_id uuid, p_semana int)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  yo public.jugadores;
  c public.config;
  v_ini timestamptz; v_fin timestamptz;
  h jsonb; v_rev boolean;
begin
  yo := public._yo(p_token);
  select * into c from public.config where id = 1;
  if p_semana < 1 or p_semana > c.semana then raise exception 'OPCION_INVALIDA'; end if;
  v_ini := public._ini_semana(p_semana);
  v_fin := coalesce((select s.creado from public.sucesos s where s.tipo = 'semana' and (s.dato->>'semana')::int = p_semana + 1 order by s.id desc limit 1), now());
  select resultados into h from public.historial where semana = p_semana;
  v_rev := h is not null and (p_semana < c.semana or c.gala_revelada);      -- los puntos se saben hasta la pasarela
  return jsonb_build_object(
    'semana', p_semana, 'revelada', v_rev,
    'puntos', case when v_rev then coalesce((select (t->>'puntos')::int from jsonb_array_elements(h->'tabla') t where t->>'id' = p_id::text), 0) end,
    'lider', case when h is not null then (h->>'lider_id') = p_id::text else c.semana = p_semana and c.lider_id = p_id end,
    'eliminado', v_rev and (h->>'eliminado_id') = p_id::text,
    'duelos', (select count(*) from public.duelos d where d.estado = 'terminado' and p_id in (d.reta, d.retado) and d.fin >= v_ini and d.fin < v_fin),
    'duelos_g', (select count(*) from public.duelos d where d.estado = 'terminado' and d.ganador = p_id and d.fin >= v_ini and d.fin < v_fin),
    'misiones', (select count(*) from public.misiones m where m.semana = p_semana and m.jugador_id = p_id and m.cumplida is not null),
    'partidas', (select count(*) from public.partidas x where x.jugador_id = p_id and x.juego <> 'duelo' and x.creado >= v_ini and x.creado < v_fin),
    'mejores', (select coalesce(jsonb_object_agg(z.juego, z.mejor), '{}'::jsonb) from (select x.juego, max(x.puntaje) as mejor from public.partidas x
                 where x.jugador_id = p_id and x.juego <> 'duelo' and x.creado >= v_ini and x.creado < v_fin group by x.juego) z),
    'generado', (select coalesce(sum(m.monto), 0) from public.movimientos m where m.jugador_id = p_id and m.creado >= v_ini and m.creado < v_fin and m.concepto not like 'Tienda: %'),
    'encuestas', (select count(*) from public.encuesta_votos ev join public.encuestas e on e.id = ev.encuesta_id
                   where ev.jugador_id = p_id and e.abre >= v_ini and e.abre < v_fin),
    'apuestas_g', (select count(*) from public.apuestas a where a.jugador_id = p_id and a.creado >= v_ini and a.creado < v_fin and a.pago > a.monto),
    'apuestas_p', (select count(*) from public.apuestas a where a.jugador_id = p_id and a.creado >= v_ini and a.creado < v_fin and a.pago = 0),
    'votos', case when p_id = yo.id then (select coalesce(jsonb_agg(jsonb_build_object('id', v.votado_id, 'nombre', j.nombre, 'puntos', v.puntos, 'motivo', v.motivo)
                 order by v.puntos desc), '[]'::jsonb) from public.votos v join public.jugadores j on j.id = v.votado_id where v.semana = p_semana and v.votante_id = yo.id) end,
    'motivos', case when p_id = yo.id and v_rev then (select coalesce(jsonb_agg(v.motivo order by v.puntos desc), '[]'::jsonb) from public.votos v
                 where v.semana = p_semana and v.votado_id = yo.id and not v.es_publico and not v.oculto and btrim(coalesce(v.motivo, '')) <> '') end);
end $$;

notify pgrst, 'reload schema';
