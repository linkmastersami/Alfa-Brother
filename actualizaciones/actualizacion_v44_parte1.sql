-- ALFA BROTHER · ACTUALIZACIÓN v44 · PARTE 1 de 2: la prueba puede abrir después de que empieza la semana
-- Pégala en SQL Editor → Run.


alter table public.config add column if not exists prueba_abre    timestamptz;
alter table public.config add column if not exists ag_prueba_abre timestamptz;

create or replace function public.iniciar_prueba(p_token uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  yo public.jugadores;
  c public.config;
  v_n int;
begin
  yo := public._yo(p_token);
  select * into c from public.config where id = 1;
  if c.fase <> 'prueba' then raise exception 'PRUEBA_CERRADA'; end if;
  if c.prueba_abre > now() then raise exception 'PRUEBA_NO_ABRE'; end if;
  if yo.rol <> 'jugador' or yo.estado <> 'activo' then raise exception 'NO_PARTICIPA'; end if;

  insert into public.intentos (semana, jugador_id, prueba) values (c.semana, yo.id, c.prueba)
  on conflict (semana, jugador_id) do nothing;
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'YA_JUGASTE'; end if;

  if c.prueba = 'trivia' then
    return jsonb_build_object('prueba', 'trivia', 'preguntas',
      (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'pregunta', t.pregunta, 'opciones', to_jsonb(t.opciones))
                       order by random()), '[]'::jsonb)
         from public.trivia t where t.activa));
  end if;
  return jsonb_build_object('prueba', c.prueba);
end $$;

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
         es_final = v_final, lider_id = case when v_final then null else c.lider_id end, eliminado_id = null,
         prueba_abre = case when not v_final and c.ag_semana = c.semana + 1 and c.ag_prueba_abre > now() then c.ag_prueba_abre end,   -- v43: el líder sigue hasta que se nombra el siguiente
         empatados = '{}', gala_revelada = false, actualizado = now()
   where id = 1;
  insert into public.sucesos (tipo, dato) values ('semana', jsonb_build_object('semana', c.semana + 1, 'prueba', case when v_final then null else p_prueba end, 'final', v_final));
  update public.practicas set mejor = 0 where mejor <> 0;     -- v40: los récords vuelven a cero cada semana
  -- misiones secretas de la semana nueva
  begin perform public._repartir_misiones(c.semana + 1, false);
  exception when others then null; end;
end $$;

revoke all on function public._iniciar_semana(text) from public, anon, authenticated;

create or replace function public._revelar()
returns void language plpgsql security definer set search_path = public as $$
declare
  c public.config;
  res jsonb;
  v_max_lider int;
  v_max_otros int;
begin
  select * into c from public.config where id = 1 for update;
  if c.fase <> 'gala' or c.gala_revelada or (c.eliminado_id is null and not c.es_final and cardinality(c.empatados) < 2) then raise exception 'FASE_INCORRECTA'; end if;

  res := public._resultados(c.semana);

  -- gran final: menos puntos = mejor lugar; los empatados comparten lugar
  if c.es_final then
    insert into public.historial (semana, resultados) values (c.semana, jsonb_build_object(
      'semana', c.semana, 'final', true,
      'eliminado_id', null, 'eliminado', null, 'lider_id', null, 'lider', null,
      'lider_salvado', false, 'desempate', false,
      'podio', (select jsonb_agg(jsonb_build_object('id', x->>'id', 'nombre', x->>'nombre', 'puntos', (x->>'puntos')::int, 'lugar', lugar)
                                 order by lugar, x->>'nombre')
                  from (select x, dense_rank() over (order by (x->>'puntos')::int) as lugar
                          from jsonb_array_elements(res) x) t),
      'tabla', res))
    on conflict (semana) do update set resultados = excluded.resultados, creado = now();
    update public.config set gala_revelada = true, terminado = true, actualizado = now(),
           ag_semana = null, ag_prueba_ini = null, ag_prueba_fin = null, ag_voto_ini = null, ag_voto_fin = null, ag_gala = null
     where id = 1;
    return;
  end if;
  select max((x->>'puntos')::int) filter (where (x->>'id')::uuid = c.lider_id),
         max((x->>'puntos')::int) filter (where (x->>'id')::uuid is distinct from c.lider_id)
    into v_max_lider, v_max_otros
    from jsonb_array_elements(res) x;

  insert into public.historial (semana, resultados) values (c.semana, jsonb_build_object(
    'semana', c.semana,
    'eliminado_id', c.eliminado_id,
    'eliminado', (select nombre from public.jugadores where id = c.eliminado_id),
    'lider_id', c.lider_id,
    'lider', (select nombre from public.jugadores where id = c.lider_id),
    'lider_salvado', coalesce(v_max_lider > 0 and v_max_lider >= v_max_otros, false),
    'desempate', cardinality(c.empatados) > 1,
    'empatados', to_jsonb(c.empatados),
    'empate_pendiente', c.eliminado_id is null,                  -- v27: lo decide el líder en la pasarela
    'decidio', case when cardinality(c.empatados) > 1 and c.eliminado_id is not null then 'lider' end,
    'resumen', public._resumen_semana(c.semana),
    'tabla', res))
  on conflict (semana) do update set resultados = excluded.resultados, creado = now();

  update public.config set gala_revelada = true, actualizado = now() where id = 1;
  if c.eliminado_id is not null then
    update public.jugadores set estado = 'eliminado', semana_eliminado = c.semana where id = c.eliminado_id;
    perform public._liquidar('eliminado', c.semana, array[c.eliminado_id::text], format('eliminado de la semana %s', c.semana));
  end if;
  if (select count(*) from public.jugadores where rol = 'jugador' and estado = 'activo') <= 1 then
    -- fue la gran final: se apaga la agenda para que no empiece otra semana
    update public.config set ag_semana = null, ag_prueba_ini = null, ag_prueba_fin = null, ag_prueba_abre = null,
           ag_voto_ini = null, ag_voto_fin = null, ag_gala = null where id = 1;
  elsif c.ag_repetir and c.ag_semana = c.semana then
    update public.config
       set ag_semana = ag_semana + 1,
           ag_prueba_ini = ag_prueba_ini + interval '7 days', ag_prueba_fin = ag_prueba_fin + interval '7 days', ag_prueba_abre = ag_prueba_abre + interval '7 days',
           ag_voto_ini = ag_voto_ini + interval '7 days', ag_voto_fin = ag_voto_fin + interval '7 days',
           ag_gala = ag_gala + interval '7 days'
     where id = 1;
  end if;
end $$;

revoke all on function public._revelar() from public, anon, authenticated;

create or replace function public.admin_set_agenda(p jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._solo_admin();
  if p is null then
    update public.config set ag_semana = null, ag_prueba = null, ag_prueba_ini = null, ag_prueba_fin = null, ag_prueba_abre = null,
           ag_voto_ini = null, ag_voto_fin = null, ag_gala = null, actualizado = now() where id = 1;
    return;
  end if;
  if coalesce(p->>'prueba', 'memoria') not in ('trivia','memoria','adeudo','billetes') then raise exception 'PRUEBA_INVALIDA'; end if;
  update public.config
     set ag_semana     = (p->>'semana')::int,
         ag_prueba     = coalesce(p->>'prueba', 'memoria'),
         ag_prueba_ini = nullif(p->>'prueba_ini', '')::timestamptz,
         ag_prueba_fin = nullif(p->>'prueba_fin', '')::timestamptz,
         ag_prueba_abre = nullif(p->>'prueba_abre', '')::timestamptz,
         ag_voto_ini   = nullif(p->>'voto_ini', '')::timestamptz,
         ag_voto_fin   = nullif(p->>'voto_fin', '')::timestamptz,
         ag_gala       = nullif(p->>'gala', '')::timestamptz,
         ag_repetir    = coalesce((p->>'repetir')::boolean, true),
         actualizado   = now()
   where id = 1;
end $$;

create or replace function public.admin_prueba_abre(p_cuando timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare c public.config; v_n text;
begin
  perform public._solo_admin();
  select * into c from public.config where id = 1;
  if c.fase <> 'prueba' then raise exception 'FASE_INCORRECTA'; end if;
  update public.config set prueba_abre = case when p_cuando > now() then p_cuando end, actualizado = now() where id = 1;
  if p_cuando is null or p_cuando <= now() then
    v_n := case c.prueba when 'trivia' then 'Trivia de la oficina' when 'memoria' then 'Memoria de expedientes'
                         when 'adeudo' then 'Calcula el adeudo' when 'billetes' then 'Cuenta los billetes verdes' else 'la prueba' end;
    perform public._avisar('🏆 ¡Ya abrió la prueba del líder!', format('Ya puedes jugar %s. Solo tienes un intento.', v_n));
  end if;
end $$;

create or replace function public._prueba_abre_aviso()
returns void language plpgsql security definer set search_path = public as $$
declare c public.config; v_n text;
begin
  select * into c from public.config where id = 1;
  if c.fase <> 'prueba' or c.prueba_abre is null or c.prueba_abre > now() then return; end if;
  update public.config set prueba_abre = null where id = 1 and prueba_abre is not null and prueba_abre <= now();
  if not found then return; end if;
  v_n := case c.prueba when 'trivia' then 'Trivia de la oficina' when 'memoria' then 'Memoria de expedientes'
                       when 'adeudo' then 'Calcula el adeudo' when 'billetes' then 'Cuenta los billetes verdes' else 'la prueba' end;
  perform public._avisar('🏆 ¡Ya abrió la prueba del líder!', format('Ya puedes jugar %s. Solo tienes un intento.', v_n));
end $$;

revoke all on function public._prueba_abre_aviso() from public, anon, authenticated;

create or replace function public._reloj()
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._avanzar_agenda();
  perform public._recordatorios();
  perform public._encuestas();
  begin perform public._noticiero_aviso(); exception when others then null; end;
  begin perform public._cerrar_duelos(); exception when others then null; end;
  begin perform public._empate_vencido(); exception when others then null; end;
  begin perform public._prueba_abre_aviso(); exception when others then null; end;
end $$;

revoke all on function public._reloj() from public, anon, authenticated;

notify pgrst, 'reload schema';
