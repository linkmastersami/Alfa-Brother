-- ALFA BROTHER · ACTUALIZACIÓN v60 (parte 1 de 2): Cobranza furiosa guarda récords y paga por jugar
-- Pégala en SQL Editor → Run. Luego corre la parte 2.

alter table public.practicas drop constraint if exists practicas_juego_check;
alter table public.practicas add constraint practicas_juego_check check (juego in ('memoria','adeudo','monster','monster2','billetes','cobranza'));

create or replace function public._pago_jugar(p_yo uuid, p_juego text, p_puntaje int, p_fijo int default null)
returns int language plpgsql security definer set search_path = public as $$
declare v int; v_ref numeric; v_hoy int;
begin
  v_ref := case p_juego when 'memoria' then 713 when 'adeudo' then 1450 when 'billetes' then 500 when 'cobranza' then 60000 else 54228 end;   -- v60: Cobranza furiosa
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
  if p_juego not in ('memoria', 'adeudo', 'monster', 'monster2', 'billetes', 'cobranza') then raise exception 'JUEGO_INVALIDO'; end if;
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

create or replace function public._stats_lider(p_semana int)
returns table (jugador_id uuid, misiones int, jugadas int, duelos_g int, rec numeric)
language sql stable security definer set search_path = public as $$
  with v as (select public._ini_semana(p_semana) as ini),     -- v43: solo lo de esta semana (desde que empezó hasta que cierra la prueba)
  pa as (select p.jugador_id, p.juego, count(*) as n, max(p.puntaje) as mejor
           from public.partidas p, v where p.creado >= v.ini and p.juego <> 'duelo' group by 1, 2),
  tops as (select pa.juego, max(pa.mejor) as top from pa join public.jugadores jj on jj.id = pa.jugador_id and jj.rol = 'jugador'
            where pa.juego in ('monster2', 'memoria', 'adeudo', 'billetes', 'cobranza') group by pa.juego having max(pa.mejor) > 0)
  select j.id,
    least(5, (select count(*) from public.misiones m where m.semana = p_semana and m.jugador_id = j.id and m.cumplida is not null))::int,
    ((select coalesce(sum(pa.n), 0) from pa where pa.jugador_id = j.id)
      + (select count(*) from public.duelos d, v where d.estado = 'terminado' and j.id in (d.reta, d.retado) and d.fin >= v.ini))::int,
    (select count(*) from public.duelos d, v where d.estado = 'terminado' and d.ganador = j.id and d.fin >= v.ini)::int,
    round(coalesce((select sum(least(1, pa.mejor::numeric / t.top)) from pa join tops t on t.juego = pa.juego where pa.jugador_id = j.id)
                   / nullif((select count(*) from tops), 0), 0), 3)
  from public.jugadores j where j.rol = 'jugador' and j.estado = 'activo'
$$;
revoke all on function public._stats_lider(int) from public, anon, authenticated;

notify pgrst, 'reload schema';
