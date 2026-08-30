# YouTube Cygnus — handoff visible para Director y trabajadores

Fecha: 2026-08-30 UTC  
Proyecto: Skool proyecto / Academia  
Estado: INVENTARIO Y PREPRODUCCIÓN COMPLETADOS / CAMBIOS PÚBLICOS PENDIENTES

## Resumen ejecutivo

La infraestructura de YouTube dejó de estar pendiente. OAuth, refresh token cifrado, lectura desatendida por API y evidencia durable están operativos.

Canal autenticado exacto:

- Nombre actual: `ruben espana`
- Channel ID: `UCZhxLanR9eh7u2PtMv9Bxjg`
- Handle actual: `@rubenespana4255`
- Videos: `0`
- Playlists: `0`
- Secciones de Home: `0`
- Descripción: vacía
- Avatar actual: identidad `INVESTMENTS ESPAÑA`
- Evidencia API: `director_external_evidence.id=45`, `status=pass`, `verified=true`
- Secretos expuestos: `0`
- Eliminaciones y publicaciones: `0`

## Terminado y no debe repetirse

1. No repetir OAuth de Google/YouTube.
2. No pedir contraseñas, cookies, access tokens ni refresh tokens.
3. No volver a crear conectores ni cuentas.
4. No repetir el inventario inicial salvo comprobación posterior a un cambio.
5. No buscar videos antiguos: la API certificó cero videos.
6. No subir ni publicar el Short sin el gate humano indicado.

## Entregables listos

- Informe canónico: `academy/handoffs/YOUTUBE_CYGNUS_MIGRATION_AUDIT_2026-08-30.md`
- Banner: `academy/social/youtube/branding/cygnus_youtube_banner_2560x1440.jpg`
- Avatar: `academy/social/youtube/branding/cygnus_youtube_avatar_800x800.jpg`
- Watermark: `academy/social/youtube/branding/cygnus_youtube_watermark_150x150.png`
- Short privado de prueba: `academy/social/youtube/test-short/cygnus_youtube_short_test_v1.mp4`
- Subtítulos: `academy/social/youtube/test-short/cygnus_youtube_short_test_v1.srt`

El Short está en estado `DRAFT_NOT_UPLOADED`, 1080×1920, H.264, 30 segundos, sin voz pendiente de decisión.

## Instrucciones que debe emitir Dirección

Dirección debe confirmar y asignar estas decisiones en orden:

### D1 — Nombre maestro

Confirmar una sola opción multicanal:

- Recomendación por coherencia actual: `Cygnus Academy AI`
- Alternativa que exige cambio global coordinado: `Cygnus Academy IA`

No cambiar únicamente YouTube a `IA` mientras Facebook e Instagram permanecen en `AI`.

### D2 — Aplicación pública en YouTube Studio

Asignar a un operador con la sesión correcta:

1. Guardar el nombre aprobado.
2. Intentar `@CygnusAcademyAI`; usar `@CygnusAcademyIA` solo si D1 lo autorizó.
3. Cargar avatar, banner y watermark preparados.
4. Añadir descripción institucional y enlaces verificados.
5. Tomar evidencia antes/después.
6. No crear playlists vacías todavía.

### D3 — QA posterior

Después de aplicar D2:

1. Revisar escritorio y móvil auténtico.
2. Verificar nombre, handle, avatar, banner, descripción, enlaces y ausencia de Investments España.
3. Ejecutar nuevamente el inventario API.
4. Registrar una nueva evidencia posterior sin sobrescribir la evidencia 45.

### D4 — Prueba privada

Dirección debe escoger:

- voz institucional aprobada;
- versión sin voz; o
- mantener el Short en espera.

Solo después puede autorizarse el upload con privacidad `private`. La publicación pública requiere una segunda aprobación separada.

### D5 — Organización editorial

Una vez exista contenido aprobado, crear en este orden:

1. Empieza aquí.
2. Shorts | IA aplicada.
3. IA aplicada al trabajo.
4. Automatización y agentes.
5. Auditoría 360.
6. Clases y cursos.
7. Profesores y avatares, únicamente cuando existan docentes aprobados.

## Flujo operativo obligatorio

`Director → guion → assets/video → voz/subtítulos → QA → RARA → adaptación YouTube/Shorts → aprobación humana → upload privado → QA posterior → aprobación separada de publicación`

## Guardrails

- Cero eliminación permanente.
- Cero duplicación de cuentas.
- Cero exposición de secretos.
- Cero upload o publicación sin aprobación.
- No atribuir contenido anterior a Cygnus.
- No cambiar seguridad, propiedad, administradores ni recuperación.
- Conservar la evidencia 45 y todos los assets originales.

## Solicitud al Director

Evaluar D1–D5, registrar las decisiones y asignar la siguiente ejecución. La prioridad recomendada es D1 → D2 → D3. D4 y D5 pueden permanecer en preparación hasta que la identidad pública quede certificada.
