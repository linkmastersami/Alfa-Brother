-- ALFA BROTHER · ACTUALIZACIÓN v76: cambiar el juego de la prueba ya empezada
-- Pégala en SQL Editor → Run.

-- v76: cambiar el juego de la prueba ya empezada (se borran los intentos de la semana y todos juegan el nuevo)
create or replace function public.admin_cambiar_prueba(p_prueba text)
returns int language plpgsql security definer set search_path = public as $$
declare c public.config; v_n int; v_nom text;
begin
  perform public._solo_admin();
  select * into c from public.config where id = 1 for update;
  if c.fase <> 'prueba' then raise exception 'FASE_INCORRECTA'; end if;
  if p_prueba not in ('trivia','memoria','adeudo','billetes') then raise exception 'PRUEBA_INVALIDA'; end if;
  if p_prueba = 'trivia' and not exists (select 1 from public.trivia where activa) then raise exception 'SIN_TRIVIAS'; end if;
  delete from public.intentos where semana = c.semana;
  get diagnostics v_n = row_count;
  update public.config set prueba = p_prueba, actualizado = now() where id = 1;
  v_nom := case p_prueba when 'trivia' then 'Trivia de la oficina' when 'memoria' then 'Memoria de expedientes'
                         when 'adeudo' then 'Calcula el adeudo' when 'billetes' then 'Cuenta los billetes verdes' end;
  if c.prueba_abre is null or c.prueba_abre <= now() then
    perform public._avisar('🔄 Cambió la prueba del líder', format('Ahora la prueba es %s. Si ya habías jugado, vuelve a jugar: se reinició para todos.', v_nom));
  end if;
  return v_n;
end $$;

notify pgrst, 'reload schema';
