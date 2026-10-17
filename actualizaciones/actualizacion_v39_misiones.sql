-- ALFA BROTHER · ACTUALIZACIÓN v39: 28 misiones nuevas de actividades
-- Pégala en SQL Editor → Run. No borra nada.

-- v39: misiones de actividades (hacer algo, no decir frases)
insert into public.misiones_banco (texto) values
  ('Juega un duelo de Boxeo 🤜🤛 contra {nombre}.'),
  ('Juega un duelo de Globo explosivo 🎈💥 contra {nombre}.'),
  ('Juega el puente de cristal 🪟 contra {nombre}.'),
  ('Juega un duelo de Cálculo rápido contra {nombre}.'),
  ('Reta a {nombre} a un duelo con apuesta de $300 o más, y que acepte.'),
  ('Juega 3 duelos contra {nombre} en la semana.'),
  ('Jueguen al mismo tiempo un juego de práctica tú y {nombre}, y comparen puntajes.'),
  ('Haz que {nombre} silbe una canción.'),
  ('Haz que {nombre} tararee la canción de Big Brother (o la que tú escojas).'),
  ('Haz que {nombre} baile aunque sea 5 segundos.'),
  ('Haz que {nombre} haga una imitación de alguien famoso.'),
  ('Haz que {nombre} aplauda 3 veces seguidas.'),
  ('Haz que {nombre} haga 5 sentadillas.'),
  ('Haz que {nombre} se pare en un pie por 10 segundos.'),
  ('Haz que {nombre} haga una pose de superhéroe.'),
  ('Haz que {nombre} dibuje algo en un papel y te lo regale.'),
  ('Juega piedra, papel o tijeras en persona con {nombre}.'),
  ('Hagan una carrera con {nombre} de quién termina primero su café o su agua.'),
  ('Haz un concurso de miradas con {nombre}.'),
  ('Juega gato (tres en línea) en papel con {nombre}.'),
  ('Haz que {nombre} te ayude a acomodar algo de tu escritorio.'),
  ('Hagan juntos tú y {nombre} una torre con 5 objetos de la oficina.'),
  ('Hazle un avión de papel a {nombre} y que lo lance.'),
  ('Ponte de acuerdo con {nombre} para llegar vestidos del mismo color un día.'),
  ('Tómate una foto con {nombre} haciendo los dos la misma cara chistosa.'),
  ('🎃 Asusta a {nombre} sin que se dé cuenta de que vienes.'),
  ('🎃 Haz que {nombre} haga su mejor cara de zombi 🧟.'),
  ('🎃 Regálale un dulce a {nombre} y que te dé otro a cambio.')
on conflict (texto) do nothing;
