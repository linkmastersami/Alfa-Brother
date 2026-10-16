-- ALFA BROTHER · ACTUALIZACIÓN v37 · PARTE 2 de 2 (quién aún no vota + Halloween)
-- Pégala en SQL Editor → Run.

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
        'voto_ini', c.ag_voto_ini, 'voto_fin', c.ag_voto_fin, 'gala', c.ag_gala) end,
      'semana', c.semana, 'fase', c.fase, 'prueba', c.prueba, 'cupo', c.cupo,
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
    -- v34: habitantes que todavía no votan (solo mientras está abierta la votación; no dice por quién votó nadie)
    'sin_votar', case when c.fase = 'votacion' then (select coalesce(jsonb_agg(j.id order by j.nombre), '[]'::jsonb)
        from public.jugadores j where j.rol = 'jugador'
         and not exists (select 1 from public.votos v where v.semana = c.semana and v.votante_id = j.id)) end
  ) || public._economia(yo.id, v_bono) || public._duelos_estado(yo.id);
end $$;

-- v37: 🎃 especial de Halloween (cada artículo va en su lugar de siempre: sombrero, lentes, mano…)
alter table public.tienda add column if not exists temporada text;
insert into public.tienda (id, tipo, nombre, icono, precio, orden, temporada) values
  ('h_fantasma',  'sombrero', 'Fantasmita',          '👻',  1200, 20, 'halloween'),
  ('h_murcielago','sombrero', 'Murciélago',          '🦇',  1400, 21, 'halloween'),
  ('h_telarana',  'sombrero', 'Telaraña',            '🕸️',  1600, 22, 'halloween'),
  ('h_calavera',  'sombrero', 'Calaverita',          '💀',  2400, 23, 'halloween'),
  ('h_antifaz',   'lentes',   'Antifaz de teatro',   '🎭',  1500, 20, 'halloween'),
  ('h_ogro',      'lentes',   'Máscara de ogro',     '👹',  2200, 21, 'halloween'),
  ('h_zombi',     'color',    'Zombi',               '#7BB661',  900, 20, 'halloween'),
  ('h_calabaza',  'color',    'Calabaza',            '#FF7A1A',  900, 21, 'halloween'),
  ('h_bruja',     'color',    'Bruja',               '#8E4FD6',  900, 22, 'halloween'),
  ('h_ectoplasma','color',    'Ectoplasma',          '#7CFFB2', 1800, 23, 'halloween'),
  ('h_dulce',     'mano',     'Dulce',               '🍬',   500, 20, 'halloween'),
  ('h_paleta',    'mano',     'Paleta',              '🍭',   600, 21, 'halloween'),
  ('h_hueso',     'mano',     'Hueso',               '🦴',   800, 22, 'halloween'),
  ('h_vela',      'mano',     'Vela',                '🕯️',  1000, 23, 'halloween'),
  ('h_escoba',    'mano',     'Escoba de bruja',     '🧹',  1500, 24, 'halloween'),
  ('h_bola',      'mano',     'Bola de cristal',     '🔮',  2500, 25, 'halloween'),
  ('h_arana',     'mascota',  'Araña',               '🕷️',  2000, 20, 'halloween'),
  ('h_buho',      'mascota',  'Búho',                '🦉',  2800, 21, 'halloween'),
  ('h_gatonegro', 'mascota',  'Gato negro',          '🐈‍⬛',  3200, 22, 'halloween'),
  ('h_murci_m',   'mascota',  'Murcielaguito',       '🦇',  3500, 23, 'halloween'),
  ('h_fantasmas', 'efecto',   'Fantasmas',           '👻',  4000, 20, 'halloween'),
  ('h_murcis',    'efecto',   'Murciélagos',         '🦇',  4000, 21, 'halloween'),
  ('h_dulces',    'efecto',   'Lluvia de dulces',    '🍬',  4500, 22, 'halloween'),
  ('h_calabazas', 'efecto',   'Calabazas',           '🎃',  5000, 23, 'halloween')
on conflict (id) do update set tipo = excluded.tipo, nombre = excluded.nombre, icono = excluded.icono,
                               precio = excluded.precio, orden = excluded.orden, temporada = excluded.temporada;
update public.tienda set temporada = 'halloween' where id = 'calabaza';

create or replace function public.tienda_lista()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'tipo', tipo, 'nombre', nombre, 'icono', icono, 'precio', precio, 'temporada', temporada)
                  order by tipo, orden), '[]'::jsonb) from public.tienda;
$$;

notify pgrst, 'reload schema';
