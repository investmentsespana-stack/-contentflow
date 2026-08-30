# YouTube — auditoría, migración y preproducción Cygnus

Fecha: 2026-08-30 UTC

## Límite de esta ejecución

Se hizo inventario primero y no se borró, ocultó, modificó ni publicó contenido. No se cambió todavía el nombre, handle, avatar, banner, enlaces ni configuración pública. El upload real permanece detrás de aprobación humana.

## Canal autenticado verificado por API

| Campo | Estado observado |
|---|---|
| Canal | `ruben espana` |
| Channel ID | `UCZhxLanR9eh7u2PtMv9Bxjg` |
| Handle | `@rubenespana4255` |
| URL estable | `https://www.youtube.com/channel/UCZhxLanR9eh7u2PtMv9Bxjg` |
| Creación | `2022-10-20T22:07:14.703853Z` |
| Descripción | Vacía |
| País / idioma | No configurados en la respuesta API |
| Visibilidad del canal | `public` |
| Vinculado | `isLinked: true` |
| Uploads largos | `eligible` |
| Monetización | No habilitada |
| Suscriptores / vistas / videos | `0 / 0 / 0` |
| Playlists propias | `0` |
| Secciones de inicio | `0` |

Evidencia de lectura: esquema `nexo.youtube.channel.inventory.v1`, ledger `director_external_evidence.id=45`, `status=pass`, `verified=true`, comprobado `2026-08-30T18:24:12.749Z`.

La foto actual fue descargada desde la miniatura devuelta por la API y contiene la identidad gráfica `INVESTMENTS ESPAÑA`; SHA-256 `32c08eceb130af033dd61e7b9c3f50dc34e2ab27d24bc590f8929d61a2aa4e19`. La API no devolvió una URL de banner. YouTube Data API no expone el estado del watermark ni todos los enlaces/configuraciones de Studio, por lo que esos campos requieren verificación visual posterior en Studio.

## Conexión ContentFlow / Nexo

Estado: `CONECTADA Y OPERATIVA`.

- OAuth real y refresh token persistido cifrado en `public.youtube_oauth_token_vault`.
- Permisos concedidos: `https://www.googleapis.com/auth/youtube` y `https://www.googleapis.com/auth/youtube.upload`.
- La lectura desatendida descifra y refresca el token únicamente dentro del runtime server-side.
- La acción `GET|POST /api/youtube/demo?action=inventory` guarda la instantánea completa en el ledger protegido y responde solo con un recibo no secreto.
- Recibo posterior: canal `UCZhxLanR9eh7u2PtMv9Bxjg`, título `ruben espana`, `videoCount=0`, `playlistCount=0`, `secretsExposed=false`.
- Ningún access token, refresh token, client secret, cookie ni contraseña fue mostrado o escrito en GitHub.

## Migración preparada

Nombre público recomendado: `Cygnus Academy AI`.

Descripción preparada:

> Cygnus Academy AI explora y demuestra aplicaciones reales de inteligencia artificial, automatización y sistemas multiagente. Aprendemos haciendo: el humano define propósito, reglas y criterio; la IA ayuda a investigar, ejecutar y verificar. Aprendiendo Haciendo – Formación para el trabajo.

Handle preferido: `@CygnusAcademyAI`. Alternativa: `@CygnusAcademyIA`.

Comprobación pública del 2026-08-30: ambos URLs devolvieron `404 Not Found`, sin canal público localizado. Esto descarta un conflicto público observable, pero no certifica la reserva; YouTube confirma disponibilidad únicamente al guardar el handle en Studio. El preferido coincide con Instagram `@cygnusacademyai` y con la marca pública de Facebook `Cygnus Academy AI`. Si Dirección decide sustituir `AI` por `IA` en toda la marca, debe hacerse como una decisión multicanal separada antes de guardar el nombre.

Enlaces preparados:

- Instagram: `https://www.instagram.com/cygnusacademyai/`
- Facebook estable por ID: `https://www.facebook.com/102575905973808`
- Web/landing Cygnus: pendiente; no se inventó dominio.

## Identidad visual YouTube preparada

| Archivo | Uso | Dimensiones | SHA-256 |
|---|---|---:|---|
| `cygnus_youtube_banner_2560x1440.jpg` | Banner | 2560×1440 | `d3b1ffc9ab0d7a601ec252902d9fb21e50d61e50b672efbdf029ac39d15e5434` |
| `cygnus_youtube_avatar_800x800.jpg` | Avatar | 800×800 | `5366ca3687abac0828cbb483c9de13d7e1ab554cb71fa36f4d4e18a7be6505a6` |
| `cygnus_youtube_watermark_150x150.png` | Watermark | 150×150 | `eac86a7a30dc65b01aa525a678260a916e631948954e2eb53fe7e9f0ace17e3d` |

Sistema: mujer profesional en banner, cisne/constelación Cygnus, navy oscuro, cian/azul, violeta, magenta moderado, esmeralda y dorado. No contiene Escuela EnDigital ni Investments España.

Las dimensiones siguen la ayuda oficial vigente: banner recomendado 2560×1440; mínimo 2048×1152, zona segura mínima 1235×338, máximo 6 MB; watermark cuadrado mínimo 150×150 y menor de 1 MB. El avatar se entrega como master 800×800 para recorte circular.

## Organización preparada

Orden de Home propuesto después de publicar contenido aprobado:

1. Trailer de presentación de Cygnus.
2. Empieza aquí.
3. Shorts: IA aplicada en menos de 60 segundos.
4. IA aplicada al trabajo.
5. Automatización y agentes.
6. Auditoría 360: antes de automatizar.
7. Clases y cursos.
8. Profesores y avatares, solo cuando existan perfiles aprobados.

Playlists preparadas: `Empieza aquí`, `Shorts | IA aplicada`, `IA aplicada al trabajo`, `Automatización y agentes`, `Auditoría 360`, `Clases y cursos`, `Profesores y avatares`.

No se crearon playlists vacías todavía; hacerlo antes de contenido aprobado no aporta navegación y sería un cambio público.

## Flujo editorial certificado como contrato

`Director → guion → assets/video → voz/subtítulos → QA → RARA → adaptación YouTube/Shorts → aprobación humana → upload privado → QA posterior → aprobación separada de publicación`

Reglas:

- Todo upload inicial se prepara con privacidad `private`.
- La aprobación de upload no equivale a aprobación de publicación.
- RARA valida claims, copyright/licencias, legibilidad, subtítulos, datos sensibles, formato, audiencia y enlaces.
- ContentFlow registra IDs y recibos; nunca registra tokens.
- Borrado permanente queda fuera del alcance y no está autorizado.

## Prueba controlada preparada

Borrador `cygnus_youtube_short_test_v1.mp4`: 1080×1920, H.264, 30 fps, 30 segundos, derivado de F02, sin audio pendiente de decisión de voz, subtítulos quemados y SRT independiente. SHA-256 `47b2b82604445e1689045e84ac2f9033a7ea307b5a15f8ea5e18c1919a573bbc`.

Estado: `DRAFT_NOT_UPLOADED`. Gate de upload: `HUMAN_APPROVAL_REQUIRED`. Gate de publicación: aprobación humana separada. No se ejecutó upload.

## Pendientes que requieren superficie Studio o decisión humana

- Confirmar si la marca maestra permanece `Cygnus Academy AI` o cambia globalmente a `Cygnus Academy IA`.
- Guardar nombre y handle; YouTube limita cambios de nombre y handle a dos veces en 14 días.
- Subir avatar, banner y watermark preparados.
- Añadir descripción y enlaces; verificar visualmente banner, enlaces y watermark.
- Configurar trailer y secciones cuando exista contenido aprobado.
- Elegir voz/licencia musical o confirmar versión sin voz para la prueba.
- Aprobar, si procede, upload privado del Short; publicar requiere una aprobación posterior distinta.

## Certificación

- Canal correcto: `VERIFICADO` por API y vault.
- API/refresh persistente: `VERIFICADO` mediante lectura posterior y evidencia 45.
- Inventario: `VERIFICADO`; cero videos, playlists y secciones, por lo que no existe contenido que borrar o migrar.
- Identidad actual anterior: `VERIFICADA` en nombre, handle y avatar; descripción vacía.
- Identidad Cygnus: `PREPARADA`, no aplicada.
- Prueba Short: `PREPARADA`, no subida.
- Branding posterior en YouTube: `REQUIERE HUMANO/STUDIO`; no puede declararse cambiado.
- Secretos expuestos: `0`.
- Eliminaciones: `0`.
