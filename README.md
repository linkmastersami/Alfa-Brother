# Alfa Brother: Te Vamos a Cobrar

Reality de votaciones para celular. Cada semana hay prueba del líder, votación 3-2-1 y gala de eliminación.

Archivos:

- `index.html`: el juego completo (esto es lo que se publica).
- `supabase.sql`: crea la base de datos en Supabase.

---

## 1. Preparar Supabase (una sola vez)

### 1.1 Crear las tablas
1. Entra a tu proyecto en supabase.com.
2. Menú izquierdo → **SQL Editor** → **New query**.
3. Copia todo el contenido de `supabase.sql`, pégalo y presiona **Run**.
   Debe decir *Success*. Si algún día lo vuelves a ejecutar, no borra datos.

### 1.2 Crear tu usuario de producción (admin)
1. Menú izquierdo → **Authentication** → **Users** → **Add user** → **Create new user**.
2. Email: `produccion@alfabrother.app`
   (es un correo inventado para que tu correo real no aparezca en el código).
3. Password: tu clave de producción.
4. Marca **Auto Confirm User** y crea el usuario.
5. Regresa a **SQL Editor** y ejecuta esto para darle permisos de admin:

```sql
insert into public.admins (user_id)
select id from auth.users where email = 'produccion@alfabrother.app';
```

> La clave **no** está escrita en el código. Vive solo en Supabase, así que aunque alguien revise el repositorio no puede verla.

### 1.3 Cerrar el registro de usuarios de Supabase (recomendado)
**Authentication** → **Sign In / Providers** → desactiva **Allow new users to sign up**.
Los jugadores no lo necesitan (usan nombre y PIN), y así nadie más puede crear cuentas.

### 1.4 Copiar los datos de conexión
**Project Settings** → **API** (en proyectos nuevos: **Data API** y **API Keys**). Copia:
- **Project URL** (algo como `https://abcdxyz.supabase.co`)
- **anon public key** (o la **publishable key**)

Abre `index.html`, busca la sección **CONFIGURACIÓN** al principio del script y pega:

```js
const SUPABASE_URL      = 'https://abcdxyz.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOi...';
```

La anon key es pública por diseño: no da acceso a los votos ni a nada privado.

---

## 2. Publicar en GitHub Pages

1. Crea un repositorio nuevo (por ejemplo `alfa-brother`).
2. Sube `index.html` (y si quieres este README y `supabase.sql`; no tienen datos secretos).
3. En el repositorio: **Settings** → **Pages** → **Source: Deploy from a branch** → rama `main`, carpeta `/ (root)` → **Save**.
4. En 1–2 minutos queda en: `https://TU-USUARIO.github.io/alfa-brother/`

> Ojo: el link lleva tu usuario de GitHub. Si quieres que nadie sepa que tú lo hiciste, publícalo desde otra cuenta de GitHub.

Comparte ese link en el grupo de la oficina.

---

## 3. Cómo se juega

- **Registro:** cada quien entra al link, pone su nombre, crea un PIN de 4 números y, si quiere, una foto. Los primeros 16 son habitantes; los demás entran como **público**.
- **Prueba del líder:** un intento por habitante. El líder sale **mitad de la prueba y mitad de las misiones secretas cumplidas la semana pasada**: la prueba da hasta 50 puntos (tu puntaje contra el mejor de la semana) y cada misión 10 (hasta 50). Solo cuenta quien jugó la prueba; en empate gana la mejor prueba y luego quien terminó primero.
- **Votación:** todos reparten **3, 2 y 1 puntos** a tres habitantes activos, con un motivo opcional. Los eliminados siguen votando y su voto cuenta. El voto del público aparece en la tabla pero no cuenta.
- **Resultado:** sale quien junte más puntos. Si el que más tiene es el líder, se salva y sale el siguiente. Si hay empate, el líder decide desde su celular.
- **Gala:** se ve el conteo de puntos de cada uno, el eliminado con el sello y los motivos de forma anónima.
- **Gran final:** cuando quedan 3 (o menos) en la casa ya no hay prueba ni líder: se abre la votación directo. Quien junte **menos** puntos gana; el que sigue queda en segundo y el más votado en tercero. Si hay empate, comparten el lugar (puede haber dos primeros o dos segundos lugares).

### Billetes Alfa y actividades

Todos (habitantes, eliminados y público) empiezan con **$2,000 Billetes Alfa** (no son dinero de verdad). Se ganan así:

| Cómo | Billetes |
|---|---|
| Entrar al juego cada día | $200 |
| Primera práctica del día de cada juego | $100 |
| Romper un récord de la casa | $200 (una vez al día por juego) |
| Cada misión secreta cumplida (hasta 5 por semana) | $300, y $50 para quien la confirma |
| Atinarle a una apuesta | tu parte del pozo |

- **Apuestas:** mientras está la prueba se apuesta quién será el líder; hasta que cierra la votación, quién sale. Lo apostado se junta en un pozo y se reparte entre los que atinaron según cuánto puso cada uno. Si nadie atina, se devuelve todo. En la gran final no hay apuestas de líder ni de eliminado. El líder siempre se decide solo entre quienes siguen en la casa.
- **Encuesta del día:** la producción la programa; todos votan en secreto y pueden apostar qué opción gana.
- **Misiones secretas:** para todos los habitantes, sigan en la casa o estén eliminados (el público no participa). Al empezar cada semana cada habitante recibe 5 misiones, cada una sobre otro habitante distinto (por ejemplo, *Haz que Karla diga "pagaré"*). Todos ven en la casa cuántas lleva cada quien. Cuando la cumples, tocas **✅ ¡Ya la cumplí!** y a esa persona le llega un aviso (o le sale en pantalla si tiene el juego abierto): **Sí, es cierto** (tú ganas $300 y ella $50) o **Eso es falso** (se cancela y la misión sigue pendiente). Solo el objetivo puede confirmarla.
- **Récords de la casa:** los mejores puntajes de Monster Crazy y de las prácticas de memoria y adeudo.
- **Monster Crazy (pestaña 🎮 Jugar):** copia adaptada del Monster Crazy del repo `juego-codigos-multijugador` (`monster.html`), solo con el enemigo clásico y con las caras de los compañeros como puntos débiles. Oleadas infinitas; la primera partida del día paga $100 y romper el récord de la casa, $200.
- **Pestañas:** 🏠 Casa (arriba, «¿Qué me toca hoy?» con el calendario de la semana y lo pendiente de cada quien), 🎮 Jugar, 💵 Billetes (saldo, apuestas y encuestas) y 🕵️ Misiones.
- **Chat de la casa:** botón flotante 💬 abajo a la derecha, solo para habitantes (en la casa y eliminados; el público no lo ve). Escribe **@** para etiquetar a alguien: le llega un aviso. Desde **Extras** puedes leer y borrar mensajes.
- **Tienda del monito:** sombreros, lentes, color del cuerpo (hasta arcoíris), algo en la mano, mascotas que caminan contigo y efectos que flotan alrededor. Precios de $400 a $8,000. Se ve en la casa, en los minijuegos y en la votación.

---

## 4. Tu panel de producción

En la pantalla de inicio o en la casa, **toca el logo (el ojo) 10 veces seguidas** y escribe tu clave.

Ciclo de cada semana desde la pestaña **Juego**:

1. **Iniciar semana** → eliges la prueba (Trivia, Memoria de expedientes o Calcula el adeudo).
2. **Cerrar prueba y nombrar líder** → automático por puntaje, o eliges a alguien.
3. **Cerrar votación** → el sistema calcula quién sale (o pide al líder que desempate).
4. **Revelar en todos los celulares** → la gala aparece sola en todos los teléfonos con el juego abierto.

Otras pestañas:

- **Votos:** quién votó por quién, con motivos. Puedes ocultar un motivo ofensivo antes de revelar la gala.
- **Pruebas:** puntajes de la semana.
- **Trivia:** escribe preguntas con 4 opciones y marca la correcta. Solo salen las **activas**; desactiva las que ya usaste.
- **Habitantes:** cambiar PIN olvidado, pasar a público, regresar a alguien a la casa, quitar foto o borrar.
- **Extras 💵:** programar la encuesta del día, ver las misiones de la semana (quién ya cumplió), repartirlas de nuevo, editar el banco de misiones (usa `{nombre}` donde va la persona objetivo) y dar o quitar billetes.

Tú juegas como cualquier otro con tu propio nombre y PIN. Si alguien te ve el celular, cierra el panel con **Cerrar**.

---

## 5. Agenda automática

En el panel → **Juego** → **Agenda de la semana N** pones día y hora para:

1. Abre la casa / empieza la prueba (y qué prueba toca)
2. Cierra la prueba: se nombra líder al mejor puntaje combinado (prueba + misiones)
3. Abre la votación
4. Cierra la votación
5. Gala: revelación del eliminado

El juego avanza solo a esas horas: cada minuto lo revisa un reloj dentro de Supabase (pg_cron), aunque nadie tenga el juego abierto. Si pg_cron no está activo, avanza cuando alguien abre el juego. Si hay empate y el líder no decide antes de la gala, el programa elige al azar. Con **Repetir cada semana**, después de cada gala la agenda se recorre 7 días sola. Lo que dejes vacío lo haces a mano con los botones de siempre.

Los jugadores ven arriba de la casa cuánto falta para lo siguiente (por ejemplo "La votación cierra en 3 h 20 min").

---

## 6. Actualizaciones de la base de datos

Cuando el juego reciba funciones nuevas que necesiten la base de datos, vuelve a ejecutar **todo** `supabase.sql` en el SQL Editor (si aparece el aviso, elige **Run and enable RLS**). No borra jugadores, votos ni trivias.

Versión 2 (sala de espera): agrega la frase de cada jugador, la predicción secreta y la cuenta regresiva.
Versión 3 (agenda y el ojo): agrega la agenda automática, la fase de espera, las pistas del ojo y la tabla de chismes.
Versión 4 (chismes del público): los jugadores pueden mandarle chismes al ojo.
Versión 5 (gran final): cuando queda un solo habitante el juego se detiene y la agenda se apaga sola, para que no empiece otra semana.
Versión 6 (podio y avisos): gran final con 3 sin prueba ni líder, podio por votos, avisos al celular y reloj automático de la agenda.
Versión 7 (Billetes Alfa): billetes, apuestas, encuesta del día, misiones secretas, récords de la casa y tienda del monito.
Versión 8 (avisos de producción): avisos solo para ti de votos, chismes, registros y empates.
Versión 9 (misiones): 5 misiones por semana para todos los habitantes, en la casa o eliminados.
Versión 10 (tienda): precios nuevos, más artículos, mascotas y efectos.
Versión 11: saldo inicial de $2,000, bono diario de $200 y práctica del día de $100.
Versión 12: los avisos de la producción se guardan en el botón 🔔 de la casa.
Versión 13: chat de la casa para los habitantes, con menciones.
Versión 14: las misiones ya no usan código QR: tocas «¡Ya la cumplí!» y la otra persona confirma o dice que es falso.
Versión 15: las misiones de la semana pasada cuentan la mitad para elegir al líder.
Versión 16: Monster Crazy (récords y premio diario) y la casa en pestañas con «¿Qué me toca hoy?».

---

## 7. Avisos al celular

El juego manda notificaciones cuando empieza la prueba, se nombra líder, abre la votación, hay empate (solo al líder), empieza la gala y hay ganador. Una hora antes de que cierre la votación le recuerda a quien no ha votado. Desde el panel (**Juego** → **Avisos al celular**) también puedes mandar un aviso a todos. Ese aviso también se guarda en el botón 🔔 de la casa, y el último sale arriba de **Habitantes** hasta que cada quien toque **Aceptar**. Desde el mismo lugar puedes borrar avisos viejos.

Se configura una sola vez:

1. Vuelve a ejecutar todo `supabase.sql` (activa `pg_net` y `pg_cron`). Si en los mensajes aparece "pg_net no está disponible" o "pg_cron no está disponible", ve a **Database** → **Extensions**, enciende **pg_net** y **pg_cron**, y ejecuta `supabase.sql` otra vez.
2. **Edge Functions** → **Deploy a new function** → **Via Editor**. Nombre: `avisos`. Borra el ejemplo, pega todo el archivo `supabase/functions/avisos/index.ts` y presiona **Deploy function**.
3. En la función, abre **Details** (o **Settings**) y apaga **Verify JWT with legacy secret** / **Enforce JWT Verification**. Guarda.
4. Abre el juego en tu celular y toca **Activar avisos**. La primera vez la función crea sus llaves sola; debe llegarte "🔔 ¡Avisos activados!".

No hay claves que copiar: las llaves viven en la tabla `push_ajustes`, que solo puede leer la producción.

**Avisos solo para la producción:** en el panel → **Juego** → **Avisos al celular** → **Recibirlos en este celular**. Te llega un aviso cuando alguien vota (y cuando ya votaron todos), cuando llega un chisme por revisar, cuando alguien se registra y cuando hay empate. Antes hay que tener activados los avisos del juego en ese mismo celular.

Cada jugador activa los avisos en su propio celular (sale una tarjeta en la casa y el enlace **Activar avisos** abajo). En **iPhone** solo funcionan con el juego instalado en la pantalla de inicio (iOS 16.4 o más nuevo) y abierto desde ahí.

---

## 8. La casa en vivo

Los monitos usan **Supabase Realtime** (presencia y mensajes en vivo); no hace falta configurar nada ni ejecutar SQL. Si la etiqueta **● N en línea** no aparece:

- Revisa en Supabase → **Project Settings** → **Realtime** que esté encendido.
- Si existe la opción **Private channels only** (o "Allow public access" apagado), déjala permitiendo canales públicos.

Sin conexión en vivo el juego sigue funcionando: todos los monitos caminan solos.

---

## 9. Problemas comunes

| Mensaje | Qué hacer |
|---|---|
| "Falta conectar Supabase" | Pega la URL y la anon key en `index.html`. |
| "Clave incorrecta" en el panel | Revisa que el usuario `produccion@alfabrother.app` exista, esté confirmado y que hayas ejecutado el `insert into public.admins`. |
| "Demasiados intentos" | Alguien falló el PIN 5 veces. Espera 10 minutos o ponle un PIN nuevo desde **Habitantes**. |
| "Activa al menos una pregunta de trivia" | Ve a **Trivia** y activa preguntas antes de iniciar una semana de trivia. |
| "Los avisos todavía no están listos" | Falta publicar la función `avisos` o apagar **Verify JWT** (ver sección 7). |
| Activé los avisos pero no llega ninguno | Revisa en **Database** → **Extensions** que **pg_net** esté encendido y vuelve a ejecutar `supabase.sql`. En **Edge Functions** → `avisos` → **Logs** se ven los errores. |
| Quiero empezar de cero | **Juego** → **Reiniciar juego** (escribe REINICIAR). Los registrados se quedan; todos regresan a $2,000 billetes y conservan lo que compraron en la tienda. |
