-- ALFA BROTHER · ACTUALIZACIÓN v44 · PARTE 2 de 2
-- Pégala en SQL Editor → Run.


create or replace function public._config_avisos()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_lider text;
  v_prueba text;
begin
  if new.fase is not distinct from old.fase and new.semana is not distinct from old.semana
     and new.gala_revelada is not distinct from old.gala_revelada then
    return new;
  end if;
  begin
    select nombre into v_lider from public.jugadores where id = new.lider_id;
    v_prueba := case new.prueba when 'trivia' then 'Trivia de la oficina' when 'memoria' then 'Memoria de expedientes'
                                when 'adeudo' then 'Calcula el adeudo' when 'billetes' then 'Cuenta los billetes verdes' else 'la prueba' end;
    if new.fase = 'prueba' and (old.fase <> 'prueba' or new.semana <> old.semana) then
      if new.prueba_abre > now() then        -- v44: la semana empezó, pero la prueba abre más tarde
        perform public._avisar(format('📅 ¡Empezó la semana %s!', new.semana),
          format('Ya tienes misiones nuevas. La prueba del líder (%s) abre el %s; mientras, ve practicando.', v_prueba,
                 to_char(new.prueba_abre at time zone 'America/Mexico_City', 'DD/MM "a las" HH24:MI')));
      else
        perform public._avisar(format('🏆 Semana %s: prueba del líder', new.semana),
                               format('Ya puedes jugar %s. Solo tienes un intento.', v_prueba));
      end if;
    elsif new.fase = 'espera' and old.fase <> 'espera' then
      if new.es_final then
        perform public._avisar('🏁 ¡Llegamos a la gran final!', 'Sin prueba ni líder: todo se decide con los votos. Ya puedes preparar tu voto.');
      elsif v_lider is not null then
        perform public._avisar(format('👑 %s es el líder de la semana', v_lider), 'La prueba cerró. Ya puedes preparar tu voto en el confesionario.');
      end if;
    elsif new.fase = 'votacion' and old.fase <> 'votacion' then
      if new.es_final then
        perform public._avisar('🏁 ¡Gran final! Ya se puede votar', 'Quien junte menos puntos gana Alfa Brother. Entra al confesionario.');
      else
        perform public._avisar('🗳️ Se abrió la votación',
          case when v_lider is not null and old.fase = 'prueba' then format('%s es el líder 👑. Entra al confesionario a votar.', v_lider)
               else 'Entra al confesionario a votar.' end);
      end if;
    elsif new.fase = 'decision' and old.fase <> 'decision' and new.lider_id is not null then
      perform public._avisar('⚖️ Hubo empate', 'Eres el líder: tú decides quién sale. Entra al juego.', array[new.lider_id]);
    end if;
    if new.fase = 'decision' and old.fase <> 'decision' then
      perform public._avisar_produccion('⚖️ Hubo empate', case when new.lider_id is null then 'No hay líder: tienes que decidir quién sale desde el panel.'
                                                              else 'El líder está decidiendo. Si tarda, puedes decidir tú desde el panel.' end);
    elsif new.fase = 'gala' and new.gala_revelada and not old.gala_revelada then
      if new.terminado then
        perform public._avisar('🏆 ¡Tenemos ganador!', 'Terminó la gran final de Alfa Brother. Entra a ver el podio.');
      else
        perform public._avisar('🎬 ¡Empezó la gala!', 'Entra a ver quién salió de la casa.');
      end if;
    end if;
  exception when others then null;
  end;
  return new;
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
        'prueba_abre', c.ag_prueba_abre, 'voto_ini', c.ag_voto_ini, 'voto_fin', c.ag_voto_fin, 'gala', c.ag_gala) end,
      'semana', c.semana, 'fase', c.fase, 'prueba', c.prueba, 'cupo', c.cupo, 'prueba_abre', c.prueba_abre,
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
