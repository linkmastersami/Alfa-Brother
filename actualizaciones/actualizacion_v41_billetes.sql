-- ALFA BROTHER · ACTUALIZACIÓN v41: Billetes verdes con rondas sin fin (paga $50 desde 500 puntos)
-- Pégala en SQL Editor → Run. (Antes debes haber corrido la v40.)


create or replace function public._pago_jugar(p_yo uuid, p_juego text, p_puntaje int, p_fijo int default null)
returns int language plpgsql security definer set search_path = public as $$
declare v int; v_ref numeric; v_hoy int;
begin
  v_ref := case p_juego when 'memoria' then 713 when 'adeudo' then 1450 when 'billetes' then 500 else 54228 end;
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

revoke all on function public._pago_jugar(uuid, text, int, int) from public, anon, authenticated;

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
  if p_juego not in ('memoria', 'adeudo', 'monster', 'monster2', 'billetes') then raise exception 'JUEGO_INVALIDO'; end if;
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

notify pgrst, 'reload schema';
