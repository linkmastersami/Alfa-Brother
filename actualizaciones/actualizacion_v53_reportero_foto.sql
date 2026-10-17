-- ALFA BROTHER · ACTUALIZACIÓN v53: fotos para el reportero
-- Pégala en SQL Editor → Run.

alter table public.reportajes add column if not exists foto text;

drop function if exists public.contar_reportero(uuid, text);
create or replace function public.contar_reportero(p_token uuid, p_texto text, p_foto text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  yo public.jugadores;
  v text := regexp_replace(btrim(coalesce(p_texto, '')), '\s+', ' ', 'g');
  f text := nullif(btrim(coalesce(p_foto, '')), '');
begin
  yo := public._yo(p_token);
  if yo.rol <> 'jugador' then raise exception 'SOLO_HABITANTES'; end if;
  if char_length(v) < 3 or char_length(v) > 500 then raise exception 'NOTICIA_INVALIDA'; end if;
  if f is not null and (f not like 'data:image/jpeg;base64,%' or char_length(f) > 450000) then raise exception 'FOTO_INVALIDA'; end if;
  if (select count(*) from public.reportajes where jugador_id = yo.id and creado > now() - interval '1 day') >= 10 then raise exception 'REPORTERO_LLENO'; end if;
  insert into public.reportajes (jugador_id, texto, foto) values (yo.id, v, f);
  perform public._avisar_produccion('🎤 Noticia para el reportero', format('%s le contó algo al reportero%s. Revísalo en el panel (pestaña Noticiero).', yo.nombre, case when f is not null then ' (con foto 📸)' else '' end));
end $$;

notify pgrst, 'reload schema';
