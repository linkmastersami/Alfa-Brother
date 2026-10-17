-- ALFA BROTHER · ACTUALIZACIÓN v54 · PARTE 2 de 2
-- Pégala en SQL Editor → Run.


create or replace function public.jugada_duelo(p_token uuid, p_id bigint, p_dato jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  yo public.jugadores;
  d public.duelos;
  k text; o text;
  n int; m int; ma int; mb int; ga int; gb int;
  v jsonb; w text;
  pw text; pa text; pb text; da int; db int; va int; vb int; mu int;
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
    if coalesce((p_dato->>'fin')::boolean, false) and now() >= d.inicio + interval '3 seconds' then
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
    -- 🪟 PUENTE DE CRISTAL (v33): {"fase": n, "lado": i} pisa el cristal i (-1 = se acabó el tiempo);
    -- {"fase": n, "piedra": i} le avienta la piedra (una por partida). Los cristales rotos se ven en los dos puentes.
    if now() < coalesce((d.datos->>('bloq' || k))::timestamptz, '-infinity'::timestamptz) then return public._duelo_vista(d.id, yo.id); end if;
    n := coalesce((d.datos->>('f' || k))::int, 0);
    if (p_dato->>'fase')::int is distinct from n or n >= jsonb_array_length(coalesce(d.datos->'opc', '[0,0,0,0,0]'::jsonb)) then return public._duelo_vista(d.id, yo.id); end if;
    mu := coalesce((d.datos->'opc'->>n)::int, 2);
    if p_dato ? 'piedra' then
      m := (p_dato->>'piedra')::int;
      if d.datos ? ('pied' || k) or m is null or m < 0 or m >= mu or d.datos->'rotos'->n @> to_jsonb(m) then
        return public._duelo_vista(d.id, yo.id);
      end if;
      if m = (d.datos->'camino'->>n)::int then
        d.datos := d.datos || jsonb_build_object('pied' || k, jsonb_build_object('f', n, 'i', m, 'ok', true));
      else
        d.datos := jsonb_set(d.datos, array['rotos', n::text], (d.datos->'rotos'->n) || to_jsonb(m))
                   || jsonb_build_object('pied' || k, jsonb_build_object('f', n, 'i', m, 'ok', false));
      end if;
      d.datos := d.datos || jsonb_build_object('plazo' || k,
        greatest(now(), coalesce((d.datos->>('plazo' || k))::timestamptz, now())) + interval '2 seconds');
      update public.duelos set datos = d.datos where id = d.id;
      return public._duelo_vista(d.id, yo.id);
    end if;
    m := (p_dato->>'lado')::int;
    if m is null or m < -1 or m >= mu or (m >= 0 and d.datos->'rotos'->n @> to_jsonb(m)) then return public._duelo_vista(d.id, yo.id); end if;
    -- se le acabaron los 6 segundos (con un poquito de tolerancia por la señal)
    if now() > coalesce((d.datos->>('plazo' || k))::timestamptz, 'infinity'::timestamptz) + interval '1.5 seconds' then m := -1; end if;
    if m = (d.datos->'camino'->>n)::int then
      d.datos := d.datos || jsonb_build_object('f' || k, n + 1, 'ult' || k, 'ok', 'col' || k, m, 'plazo' || k, now() + interval '6 seconds');
      update public.duelos set datos = d.datos where id = d.id;
      if n + 1 >= jsonb_array_length(coalesce(d.datos->'opc', '[0,0,0,0,0]'::jsonb)) then perform public._terminar_duelo(d.id, yo.id); end if;
    else            -- se cayó: el cristal se rompe (para los dos), regresa a la salida y espera 4 segundos
      if m >= 0 then d.datos := jsonb_set(d.datos, array['rotos', n::text], (d.datos->'rotos'->n) || to_jsonb(m)); end if;
      d.datos := (d.datos - ('col' || k)) || jsonb_build_object('f' || k, 0, 'ult' || k, case when m < 0 then 'tiempo' else 'cae' end,
                                               'bloq' || k, now() + interval '4 seconds', 'plazo' || k, now() + interval '10 seconds',
                                               'c' || k, coalesce((d.datos->>('c' || k))::int, 0) + 1);
      update public.duelos set datos = d.datos where id = d.id;
    end if;

  elsif d.juego = 'penales' then
    -- ⚽🧤 PENALES (v54): {"ronda": n, "lado": 0 izq | 1 centro | 2 der}. Se alternan: tira uno y tapa el otro.
    -- 5 tiros cada quien; se acaba antes si ya no se puede alcanzar; si empatan, muerte súbita.
    n := jsonb_array_length(d.datos->'tiros');
    m := (p_dato->>'lado')::int;
    if (p_dato->>'ronda')::int is distinct from n or m is null or m not between 0 and 2 or d.datos->'pend' ? k then
      return public._duelo_vista(d.id, yo.id);
    end if;
    v := d.datos->'pend' || jsonb_build_object(k, jsonb_build_object('l', m));
    if v ? 'a' and v ? 'b' then
      -- quién tira en este turno: el del volado en los pares, el otro en los nones
      w := case when n % 2 = 0 then d.datos->>'primero' else case when d.datos->>'primero' = 'a' then 'b' else 'a' end end;
      pw := case when w = 'a' then 'b' else 'a' end;
      ma := (v->w->>'l')::int; mb := (v->pw->>'l')::int;          -- ma = tiro, mb = portero
      d.datos := d.datos || jsonb_build_object('pend', '{}'::jsonb,
        'tiros', d.datos->'tiros' || jsonb_build_array(jsonb_build_object('t', w, 's', ma, 'p', mb, 'g', ma <> mb)));
      update public.duelos set datos = d.datos where id = d.id;
      -- ¿ya se decidió?
      select count(*) filter (where t->>'t' = 'a'), count(*) filter (where t->>'t' = 'b'),
             count(*) filter (where t->>'t' = 'a' and (t->>'g')::boolean), count(*) filter (where t->>'t' = 'b' and (t->>'g')::boolean)
        into va, vb, ga, gb from jsonb_array_elements(d.datos->'tiros') t;
      if va <= 5 and vb <= 5 then
        if ga + (5 - va) < gb then perform public._terminar_duelo(d.id, d.retado);
        elsif gb + (5 - vb) < ga then perform public._terminar_duelo(d.id, d.reta);
        end if;
      elsif va = vb and ga <> gb then                              -- muerte súbita: cada par de tiros
        perform public._terminar_duelo(d.id, case when ga > gb then d.reta else d.retado end);
      end if;
      if va = 5 and vb = 5 and ga <> gb then perform public._terminar_duelo(d.id, case when ga > gb then d.reta else d.retado end); end if;
      if va >= 40 then perform public._terminar_duelo(d.id, null); end if;
    else
      update public.duelos set datos = jsonb_set(d.datos, '{pend}', v) where id = d.id;
    end if;

  elsif d.juego = 'ppt' then
    -- 🤜🤛 BOXEO (v30): piedra, papel o tijeras con 3 corazones; un poder por pelea (🛡️ escudo o ⚡ golpe doble);
    -- si empatan, la siguiente ronda vale doble
    n := jsonb_array_length(d.datos->'rondas');
    m := (p_dato->>'mano')::int;
    pw := nullif(p_dato->>'poder', '');
    if (p_dato->>'ronda')::int is distinct from n or m is null or m not between 0 and 2 or d.datos->'pend' ? k then
      return public._duelo_vista(d.id, yo.id);
    end if;
    if pw is not null and (pw not in ('escudo', 'doble') or d.datos->>('pod' || k) is not null) then pw := null; end if;
    v := d.datos->'pend' || jsonb_build_object(k, jsonb_build_object('m', m, 'p', pw));
    if v ? 'a' and v ? 'b' then
      ma := (v->'a'->>'m')::int; mb := (v->'b'->>'m')::int;
      pa := v->'a'->>'p'; pb := v->'b'->>'p';
      w := case when ma = mb then '' when (ma - mb + 3) % 3 = 1 then 'a' else 'b' end;    -- papel le gana a piedra, etc.
      mu := coalesce((d.datos->>'mult')::int, 1);
      da := 0; db := 0;
      if w = 'a' then db := mu * case when pa = 'doble' then 2 else 1 end; if pb = 'escudo' then db := 0; end if;
      elsif w = 'b' then da := mu * case when pb = 'doble' then 2 else 1 end; if pa = 'escudo' then da := 0; end if;
      end if;
      va := greatest(0, coalesce((d.datos->>'va')::int, 3) - da);
      vb := greatest(0, coalesce((d.datos->>'vb')::int, 3) - db);
      d.datos := d.datos || jsonb_build_object(
        'rondas', d.datos->'rondas' || jsonb_build_array(jsonb_build_object('a', ma, 'b', mb, 'g', w, 'pa', pa, 'pb', pb, 'da', da, 'db', db, 'x', mu)),
        'va', va, 'vb', vb, 'mult', case when w = '' then 2 else 1 end, 'pend', '{}'::jsonb,
        'poda', coalesce(d.datos->>'poda', pa), 'podb', coalesce(d.datos->>'podb', pb));
      update public.duelos set datos = d.datos where id = d.id;
      if vb <= 0 then perform public._terminar_duelo(d.id, d.reta);
      elsif va <= 0 then perform public._terminar_duelo(d.id, d.retado);
      elsif n + 1 >= 15 then perform public._terminar_duelo(d.id, case when va > vb then d.reta when vb > va then d.retado end);
      end if;
    else
      update public.duelos set datos = jsonb_set(d.datos, '{pend}', v) where id = d.id;
    end if;
  end if;
  return public._duelo_vista(d.id, yo.id);
end $$;

notify pgrst, 'reload schema';
