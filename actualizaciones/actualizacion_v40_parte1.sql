-- ALFA BROTHER · ACTUALIZACIÓN v40 · PARTE 1 de 3
-- Billetes verdes, pago por jugar, líder 30/70, récords semanales. Pégala en SQL Editor → Run.


-- v40: Cuenta los billetes verdes (práctica y prueba del líder) y registro de cada partida (paga según el puntaje)
alter table public.practicas drop constraint if exists practicas_juego_check;
alter table public.practicas add constraint practicas_juego_check check (juego in ('memoria','adeudo','monster','monster2','billetes'));
alter table public.config drop constraint if exists config_prueba_check;
alter table public.config add constraint config_prueba_check check (prueba in ('trivia','memoria','adeudo','billetes'));
create table if not exists public.partidas (
  id         bigint generated always as identity primary key,
  jugador_id uuid not null references public.jugadores(id) on delete cascade,
  juego      text not null,                -- memoria, adeudo, monster2, billetes… o 'duelo'
  puntaje    int  not null default 0,
  pago       int  not null default 0,
  creado     timestamptz not null default now()
);
create index if not exists partidas_jugador on public.partidas (jugador_id, creado);

alter table public.partidas enable row level security;
drop policy if exists admin_todo on public.partidas;
create policy admin_todo on public.partidas for all to authenticated using (public.es_admin()) with check (public.es_admin());

create or replace function public._pago_jugar(p_yo uuid, p_juego text, p_puntaje int, p_fijo int default null)
returns int language plpgsql security definer set search_path = public as $$
declare v int; v_ref numeric; v_hoy int;
begin
  v_ref := case p_juego when 'memoria' then 713 when 'adeudo' then 1450 when 'billetes' then 1000 else 54228 end;
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
  v := least(greatest(coalesce(p_puntaje, 0), 0), case p_juego when 'memoria' then 1000 when 'billetes' then 1000 when 'adeudo' then 20000 else 5000000 end);
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
  with v as (select coalesce((select s.creado from public.sucesos s where s.tipo = 'semana' and (s.dato->>'semana')::int = p_semana - 1
                                order by s.id desc limit 1), now() - interval '7 days') as ini),
  pa as (select p.jugador_id, p.juego, count(*) as n, max(p.puntaje) as mejor
           from public.partidas p, v where p.creado >= v.ini and p.juego <> 'duelo' group by 1, 2),
  tops as (select pa.juego, max(pa.mejor) as top from pa join public.jugadores jj on jj.id = pa.jugador_id and jj.rol = 'jugador'
            where pa.juego in ('monster2', 'memoria', 'adeudo', 'billetes') group by pa.juego having max(pa.mejor) > 0)
  select j.id,
    least(5, (select count(*) from public.misiones m where m.semana = p_semana - 1 and m.jugador_id = j.id and m.cumplida is not null))::int,
    ((select coalesce(sum(pa.n), 0) from pa where pa.jugador_id = j.id)
      + (select count(*) from public.duelos d, v where d.estado = 'terminado' and j.id in (d.reta, d.retado) and d.fin >= v.ini))::int,
    (select count(*) from public.duelos d, v where d.estado = 'terminado' and d.ganador = j.id and d.fin >= v.ini)::int,
    round(coalesce((select sum(least(1, pa.mejor::numeric / t.top)) from pa join tops t on t.juego = pa.juego where pa.jugador_id = j.id)
                   / nullif((select count(*) from tops), 0), 0), 3)
  from public.jugadores j where j.rol = 'jugador' and j.estado = 'activo'
$$;

revoke all on function public._stats_lider(int) from public, anon, authenticated;

drop function if exists public._tabla_lider(int);

create or replace function public._tabla_lider(p_semana int)
returns table (jugador_id uuid, puntaje int, misiones int, jugadas int, duelos_g int, rec numeric,
               p_prueba numeric, p_mis numeric, p_jug numeric, p_rec numeric, p_duel numeric, total numeric, terminado timestamptz)
language sql stable security definer set search_path = public as $$
  with s as (select * from public._stats_lider(p_semana)),
  i as (
    select i.jugador_id, greatest(i.puntaje, 0) as puntaje, i.terminado
      from public.intentos i join public.jugadores j on j.id = i.jugador_id
     where i.semana = p_semana and i.puntaje is not null and j.estado = 'activo' and j.rol = 'jugador'),
  mx as (select greatest((select max(puntaje) from i), 1) as mp, greatest((select max(jugadas) from s), 1) as mj,
                greatest((select max(duelos_g) from s), 1) as md),
  t as (
    select i.jugador_id, i.puntaje, s.misiones, s.jugadas, s.duelos_g, s.rec, i.terminado,
           round(30.0 * i.puntaje / mx.mp, 1) as p_prueba, round(17.5 * s.misiones / 5, 1) as p_mis,
           round(17.5 * s.jugadas / mx.mj, 1) as p_jug, round(17.5 * s.rec, 1) as p_rec, round(17.5 * s.duelos_g / mx.md, 1) as p_duel
      from i join s on s.jugador_id = i.jugador_id, mx)
  select jugador_id, puntaje, misiones, jugadas, duelos_g, rec, p_prueba, p_mis, p_jug, p_rec, p_duel,
         p_prueba + p_mis + p_jug + p_rec + p_duel, terminado
    from t order by 12 desc, 2 desc, 13 asc
$$;

revoke all on function public._tabla_lider(int) from public, anon, authenticated;

create or replace function public.admin_tabla_lider()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._solo_admin();
  return (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from public._tabla_lider((select semana from public.config where id = 1)) t);
end $$;

create or replace function public._terminar_duelo(p_id bigint, p_ganador uuid)
returns void language plpgsql security definer set search_path = public as $$
declare d public.duelos; v_jg text; pa int; pb int;
begin
  select * into d from public.duelos where id = p_id for update;
  if not found or d.estado <> 'jugando' then return; end if;
  update public.duelos set estado = 'terminado', fin = now(), ganador = p_ganador where id = d.id;
  v_jg := public._duelo_nombre(d.juego);
  -- v40: los dos ganan $50 por jugar (si el duelo duró al menos 15 segundos; cuenta para el tope de $2,000 al día)
  if now() >= d.inicio + interval '15 seconds' then
    pa := public._pago_jugar(d.reta, 'duelo', 0, 50);
    pb := public._pago_jugar(d.retado, 'duelo', 0, 50);
    update public.duelos set datos = datos || jsonb_build_object('pago', jsonb_build_object('a', pa, 'b', pb)) where id = d.id;
  end if;
  if d.apuesta > 0 then
    if p_ganador is null then
      perform public._mover(d.reta, d.apuesta, 'Duelo empatado (' || v_jg || '): te devolvemos tu apuesta');
      perform public._mover(d.retado, d.apuesta, 'Duelo empatado (' || v_jg || '): te devolvemos tu apuesta');
    else
      perform public._mover(p_ganador, d.apuesta * 2, '¡Ganaste un duelo! (' || v_jg || ')');
    end if;
  end if;
end $$;

revoke all on function public._terminar_duelo(bigint, uuid) from public, anon, authenticated;

notify pgrst, 'reload schema';
