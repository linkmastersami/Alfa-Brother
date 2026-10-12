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
- **Prueba del líder:** un intento por habitante. Gana el mejor puntaje (en empate, quien terminó primero).
- **Votación:** todos reparten **3, 2 y 1 puntos** a tres habitantes activos, con un motivo opcional. Los eliminados siguen votando y su voto cuenta. El voto del público aparece en la tabla pero no cuenta.
- **Resultado:** sale quien junte más puntos. Si el que más tiene es el líder, se salva y sale el siguiente. Si hay empate, el líder decide desde su celular.
- **Gala:** se ve el conteo de puntos de cada uno, el eliminado con el sello y los motivos de forma anónima.

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

Tú juegas como cualquier otro con tu propio nombre y PIN. Si alguien te ve el celular, cierra el panel con **Cerrar**.

---

## 5. Actualizaciones de la base de datos

Cuando el juego reciba funciones nuevas que necesiten la base de datos, vuelve a ejecutar **todo** `supabase.sql` en el SQL Editor (si aparece el aviso, elige **Run and enable RLS**). No borra jugadores, votos ni trivias.

Versión 2 (sala de espera): agrega la frase de cada jugador, la predicción secreta y la cuenta regresiva.

---

## 6. La casa en vivo

Los monitos usan **Supabase Realtime** (presencia y mensajes en vivo); no hace falta configurar nada ni ejecutar SQL. Si la etiqueta **● N en línea** no aparece:

- Revisa en Supabase → **Project Settings** → **Realtime** que esté encendido.
- Si existe la opción **Private channels only** (o "Allow public access" apagado), déjala permitiendo canales públicos.

Sin conexión en vivo el juego sigue funcionando: todos los monitos caminan solos.

---

## 7. Problemas comunes

| Mensaje | Qué hacer |
|---|---|
| "Falta conectar Supabase" | Pega la URL y la anon key en `index.html`. |
| "Clave incorrecta" en el panel | Revisa que el usuario `produccion@alfabrother.app` exista, esté confirmado y que hayas ejecutado el `insert into public.admins`. |
| "Demasiados intentos" | Alguien falló el PIN 5 veces. Espera 10 minutos o ponle un PIN nuevo desde **Habitantes**. |
| "Activa al menos una pregunta de trivia" | Ve a **Trivia** y activa preguntas antes de iniciar una semana de trivia. |
| Quiero empezar de cero | **Juego** → **Reiniciar juego** (escribe REINICIAR). Los registrados se quedan. |
