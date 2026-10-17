-- ALFA BROTHER · ACTUALIZACIÓN v55: ya no se puede retar a Cálculo rápido
-- Pégala en SQL Editor → Run. (Antes corre la v54.)

create or replace function public.retar_duelo(p_token uuid, p_rival uuid, p_juego text, p_apuesta int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare yo public.jugadores; r public.jugadores; v_id bigint;
begin
  yo := public._yo(p_token);
  if yo.rol <> 'jugador' then raise exception 'DUELO_SOLO_HABITANTES'; end if;
  select * into r from public.jugadores where id = p_rival;
  if not found or r.rol <> 'jugador' or r.id = yo.id then raise exception 'DUELO_RIVAL_INVALIDO'; end if;
  if p_juego is null or p_juego not in ('ppt', 'globo', 'camino', 'penales') then raise exception 'OPCION_INVALIDA'; end if;   -- v55: ya no hay Cálculo rápido
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

notify pgrst, 'reload schema';
