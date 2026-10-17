-- ALFA BROTHER · ACTUALIZACIÓN v40 · PARTE 2 de 3 (corre primero la parte 1)
-- Pégala en SQL Editor → Run.


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
         es_final = v_final, lider_id = null, eliminado_id = null,
         empatados = '{}', gala_revelada = false, actualizado = now()
   where id = 1;
  insert into public.sucesos (tipo, dato) values ('semana', jsonb_build_object('semana', c.semana + 1, 'prueba', case when v_final then null else p_prueba end, 'final', v_final));
  update public.practicas set mejor = 0 where mejor <> 0;     -- v40: los récords vuelven a cero cada semana
  -- misiones secretas de la semana nueva
  begin perform public._repartir_misiones(c.semana + 1, false);
  exception when others then null; end;
end $$;

revoke all on function public._iniciar_semana(text) from public, anon, authenticated;

create or replace function public.admin_set_agenda(p jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._solo_admin();
  if p is null then
    update public.config set ag_semana = null, ag_prueba = null, ag_prueba_ini = null, ag_prueba_fin = null,
           ag_voto_ini = null, ag_voto_fin = null, ag_gala = null, actualizado = now() where id = 1;
    return;
  end if;
  if coalesce(p->>'prueba', 'memoria') not in ('trivia','memoria','adeudo','billetes') then raise exception 'PRUEBA_INVALIDA'; end if;
  update public.config
     set ag_semana     = (p->>'semana')::int,
         ag_prueba     = coalesce(p->>'prueba', 'memoria'),
         ag_prueba_ini = nullif(p->>'prueba_ini', '')::timestamptz,
         ag_prueba_fin = nullif(p->>'prueba_fin', '')::timestamptz,
         ag_voto_ini   = nullif(p->>'voto_ini', '')::timestamptz,
         ag_voto_fin   = nullif(p->>'voto_fin', '')::timestamptz,
         ag_gala       = nullif(p->>'gala', '')::timestamptz,
         ag_repetir    = coalesce((p->>'repetir')::boolean, true),
         actualizado   = now()
   where id = 1;
end $$;

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
      perform public._avisar(format('🏆 Semana %s: prueba del líder', new.semana),
                             format('Ya puedes jugar %s. Solo tienes un intento.', v_prueba));
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

create or replace function public.admin_reiniciar_juego()
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._solo_admin();
  delete from public.votos where true;
  delete from public.intentos where true;
  delete from public.historial where true;
  delete from public.predicciones where true;
  update public.jugadores set estado = 'activo', semana_eliminado = null where true;
  -- temporada nueva: todos regresan a $1,000 (lo que compraron en la tienda se queda)
  delete from public.apuestas where true;
  delete from public.movimientos where true;
  delete from public.misiones where true;
  delete from public.sucesos where true;
  delete from public.practicas where true;
  delete from public.partidas where true;
  delete from public.encuestas where liquidada;
  delete from public.duelos where true;
  update public.jugadores set billetes = 2000, ultimo_bono = null where true;
  update public.config set semana = 0, fase = 'registro', prueba = null, lider_id = null, eliminado_id = null,
         empatados = '{}', gala_revelada = false, es_final = false, terminado = false, aviso_voto = null, actualizado = now() where id = 1;
end $$;

notify pgrst, 'reload schema';
