-- ALFA BROTHER · ACTUALIZACIÓN v43 · PARTE 1 de 2
-- El líder sigue hasta que se nombra el siguiente; para ser líder cuenta solo esta semana. Pégala en SQL Editor → Run.


create or replace function public._ini_semana(p_semana int)
returns timestamptz language sql stable security definer set search_path = public as $$
  select coalesce((select s.creado from public.sucesos s where s.tipo = 'semana' and (s.dato->>'semana')::int = p_semana
                    order by s.id desc limit 1), now() - interval '7 days')
$$;

create or replace function public._generado(p_desde timestamptz)
returns table (jugador_id uuid, generado int) language sql stable security definer set search_path = public as $$
  select j.id, coalesce((select sum(m.monto) from public.movimientos m
                          where m.jugador_id = j.id and m.creado >= p_desde and m.concepto not like 'Tienda: %'), 0)::int
    from public.jugadores j
$$;

create or replace function public._stats_lider(p_semana int)
returns table (jugador_id uuid, misiones int, jugadas int, duelos_g int, rec numeric)
language sql stable security definer set search_path = public as $$
  with v as (select public._ini_semana(p_semana) as ini),     -- v43: solo lo de esta semana (desde que empezó hasta que cierra la prueba)
  pa as (select p.jugador_id, p.juego, count(*) as n, max(p.puntaje) as mejor
           from public.partidas p, v where p.creado >= v.ini and p.juego <> 'duelo' group by 1, 2),
  tops as (select pa.juego, max(pa.mejor) as top from pa join public.jugadores jj on jj.id = pa.jugador_id and jj.rol = 'jugador'
            where pa.juego in ('monster2', 'memoria', 'adeudo', 'billetes') group by pa.juego having max(pa.mejor) > 0)
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
    if p_prueba not in ('trivia','memoria','adeudo','billetes') then raise exception 'PRUEBA_INVALIDA'; end if;
    if p_prueba = 'trivia' and not exists (select 1 from public.trivia where activa) then raise exception 'SIN_TRIVIAS'; end if;
  end if;
  update public.config
     set semana = c.semana + 1,
         fase = case when not v_final then 'prueba'
                     when c.ag_semana = c.semana + 1 and c.ag_voto_ini > now() then 'espera'
                     else 'votacion' end,
         prueba = case when v_final then null else p_prueba end,
         es_final = v_final, lider_id = case when v_final then null else c.lider_id end, eliminado_id = null,   -- v43: el líder sigue hasta que se nombra el siguiente
         empatados = '{}', gala_revelada = false, actualizado = now()
   where id = 1;
  insert into public.sucesos (tipo, dato) values ('semana', jsonb_build_object('semana', c.semana + 1, 'prueba', case when v_final then null else p_prueba end, 'final', v_final));
  update public.practicas set mejor = 0 where mejor <> 0;     -- v40: los récords vuelven a cero cada semana
  -- misiones secretas de la semana nueva
  begin perform public._repartir_misiones(c.semana + 1, false);
  exception when others then null; end;
end $$;

revoke all on function public._iniciar_semana(text) from public, anon, authenticated;

create or replace function public._cerrar_prueba(p_lider uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  c public.config;
  v_lider uuid := p_lider;
begin
  select * into c from public.config where id = 1 for update;
  if c.fase <> 'prueba' then raise exception 'FASE_INCORRECTA'; end if;
  if v_lider is null then
    select t.jugador_id into v_lider from public._tabla_lider(c.semana) t limit 1;
  end if;
  update public.config
     set lider_id = coalesce(v_lider, c.lider_id),        -- v43: si nadie jugó la prueba, se queda el líder anterior
         fase = case when c.ag_semana = c.semana and c.ag_voto_ini > now() then 'espera' else 'votacion' end,
         actualizado = now()
   where id = 1;
  if v_lider is not null then
    insert into public.sucesos (tipo, jugador_id, dato) values ('lider', v_lider, jsonb_build_object('semana', c.semana, 'prueba', c.prueba));
  end if;
  perform public._liquidar('lider', c.semana, case when v_lider is null then '{}'::text[] else array[v_lider::text] end,
                           format('líder de la semana %s', c.semana));
  return v_lider;
end $$;

revoke all on function public._cerrar_prueba(uuid) from public, anon, authenticated;

create or replace function public.mis_billetes(p_token uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare yo public.jugadores;
begin
  yo := public._yo(p_token);
  return jsonb_build_object('billetes', yo.billetes, 'movimientos',
    (select coalesce(jsonb_agg(jsonb_build_object('monto', m.monto, 'concepto', m.concepto, 'creado', m.creado) order by m.creado desc, m.id desc), '[]'::jsonb)
       from (select * from public.movimientos where jugador_id = yo.id order by creado desc, id desc limit 40) m),
    -- v43: quién generó más esta semana (no quién tiene más guardado)
    'ranking', (select coalesce(jsonb_agg(jsonb_build_object('id', j.id, 'nombre', j.nombre, 'billetes', g.generado) order by g.generado desc, j.nombre), '[]'::jsonb)
       from public._generado(public._ini_semana((select semana from public.config where id = 1))) g join public.jugadores j on j.id = g.jugador_id));
end $$;

notify pgrst, 'reload schema';
