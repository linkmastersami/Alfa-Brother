-- Cópialo todo en Supabase → SQL Editor → New query → Run. No borra datos.
-- v83: en la tienda, color de la prenda de abajo y escoger pantalón o falda (para quien sea)
alter table public.tienda drop constraint if exists tienda_tipo_check;
alter table public.tienda add constraint tienda_tipo_check check (tipo in ('sombrero','lentes','color','mano','mascota','efecto','pantalon','prenda'));
insert into public.tienda (id, tipo, nombre, icono, precio, orden) values
  ('ab_mezclilla', 'pantalon', 'Mezclilla',  '#3F6DB5',  400, 1),
  ('ab_negro',     'pantalon', 'Negro',      '#23232B',  400, 2),
  ('ab_gris',      'pantalon', 'Gris',       '#7C8496',  400, 3),
  ('ab_cafe',      'pantalon', 'Café',       '#7A5230',  400, 4),
  ('ab_beige',     'pantalon', 'Beige',      '#D9C39A',  400, 5),
  ('ab_blanco',    'pantalon', 'Blanco',     '#F4F1EA',  400, 6),
  ('ab_rojo',      'pantalon', 'Rojo',       '#D7263D',  400, 7),
  ('ab_rosa',      'pantalon', 'Rosa',       '#FF6FB5',  400, 8),
  ('ab_verde',     'pantalon', 'Verde',      '#2E8B57',  400, 9),
  ('ab_morado',    'pantalon', 'Morado',     '#7A3FB5',  400, 10),
  ('ab_dorado',    'pantalon', 'Dorado',     '#FFC93C', 3000, 11),
  ('prenda_pantalon', 'prenda', 'Pantalón',  '👖',          0, 1),
  ('prenda_falda',    'prenda', 'Falda',     '👗',          0, 2)
on conflict (id) do nothing;

-- Que Supabase reconozca los cambios de inmediato
notify pgrst, 'reload schema';
