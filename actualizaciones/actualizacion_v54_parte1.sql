-- ALFA BROTHER · ACTUALIZACIÓN v54 · PARTE 1 de 2: duelo de Penales ⚽🧤
-- Pégala en SQL Editor → Run.


alter table public.duelos drop constraint if exists duelos_juego_check;
alter table public.duelos add constraint duelos_juego_check check (juego in ('ppt', 'globo', 'calculo', 'camino', 'penales'));

create or replace function public._duelo_nombre(p_juego text)
returns text language sql immutable as $$
  select case p_juego when 'ppt' then 'Boxeo' when 'globo' then 'Globo explosivo'
                      when 'calculo' then 'Cálculo rápido' when 'penales' then 'Penales' else 'El camino correcto' end
$$;

create or replace function public._duelo_limite(p_juego text)
returns interval language sql immutable as $$
  select case p_juego when 'ppt' then interval '180 seconds' when 'globo' then interval '60 seconds' when 'penales' then interval '300 seconds'
                      when 'calculo' then interval '100 seconds' else interval '240 seconds' end
$$;

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
    elsif d.juego = 'ppt' then              -- boxeo: gana quien tenía más corazones, o quien sí siguió jugando
      a := coalesce((d.datos->>'va')::int, 3); b := coalesce((d.datos->>'vb')::int, 3);
      if a > b then v_g := d.reta; elsif b > a then v_g := d.retado;
      elsif d.datos->'pend' ? 'a' and not d.datos->'pend' ? 'b' then v_g := d.reta;
      elsif d.datos->'pend' ? 'b' and not d.datos->'pend' ? 'a' then v_g := d.retado; end if;
    elsif d.juego = 'penales' then          -- gana quien lleva más goles
      select count(*) filter (where t->>'t' = 'a' and (t->>'g')::boolean), count(*) filter (where t->>'t' = 'b' and (t->>'g')::boolean)
        into a, b from jsonb_array_elements(coalesce(d.datos->'tiros', '[]'::jsonb)) t;
      if a > b then v_g := d.reta; elsif b > a then v_g := d.retado; end if;
    elsif d.juego = 'camino' then           -- gana quien llegó más lejos
      a := coalesce((d.datos->>'fa')::int, 0); b := coalesce((d.datos->>'fb')::int, 0);
      if a > b then v_g := d.reta; elsif b > a then v_g := d.retado; end if;
    end if;                                 -- en el globo, si nadie lo reventó, empate
    perform public._terminar_duelo(d.id, v_g);
  end loop;
end $$;

revoke all on function public._cerrar_duelos() from public, anon, authenticated;

create or replace function public.retar_duelo(p_token uuid, p_rival uuid, p_juego text, p_apuesta int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare yo public.jugadores; r public.jugadores; v_id bigint;
begin
  yo := public._yo(p_token);
  if yo.rol <> 'jugador' then raise exception 'DUELO_SOLO_HABITANTES'; end if;
  select * into r from public.jugadores where id = p_rival;
  if not found or r.rol <> 'jugador' or r.id = yo.id then raise exception 'DUELO_RIVAL_INVALIDO'; end if;
  if p_juego is null or p_juego not in ('ppt', 'globo', 'calculo', 'camino', 'penales') then raise exception 'OPCION_INVALIDA'; end if;
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
    -- v33: puente de cristal. 10 fases de 2 cristales; los rotos se ven en los dos puentes
    v_datos := jsonb_build_object('opc', '[2,2,2,2,2,2,2,2,2,2]'::jsonb,
      'camino', (select jsonb_agg(floor(random() * 2)::int order by g.x) from generate_series(1, 10) g(x)),
      'rotos', '[[],[],[],[],[],[],[],[],[],[]]'::jsonb, 'fa', 0, 'fb', 0, 'ca', 0, 'cb', 0,
      'plazoa', now() + interval '11 seconds', 'plazob', now() + interval '11 seconds');
  elsif d.juego = 'globo' then
    v_datos := jsonb_build_object('bombeos', 18);           -- v31: globo explosivo (sube y baja el mango)
  elsif d.juego = 'penales' then                             -- v54: penales; el volado decide quién tira primero
    v_datos := jsonb_build_object('tiros', '[]'::jsonb, 'pend', '{}'::jsonb, 'primero', case when random() < .5 then 'a' else 'b' end);
  else
    v_datos := jsonb_build_object('rondas', '[]'::jsonb, 'va', 3, 'vb', 3, 'mult', 1, 'pend', '{}'::jsonb);   -- boxeo: 3 corazones
  end if;
  update public.duelos set estado = 'jugando', inicio = now() + interval '5 seconds', datos = v_datos where id = d.id;
  perform public._avisar('⚔️ ¡Aceptaron tu duelo!', format('%s aceptó tu reto de %s. ¡Entra ya, que ya empieza!', yo.nombre, public._duelo_nombre(d.juego)), array[d.reta]);
  return public._duelo_vista(d.id, yo.id);
end $$;

notify pgrst, 'reload schema';
