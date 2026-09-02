# Social Ops — Cygnus

## Objetivo
Operar Facebook, Instagram, TikTok y YouTube de Cygnus Academy AI desde ContentFlow/Director, usando APIs oficiales cuando estén disponibles y navegador autenticado como fallback.

## Flujo
1. Director prepara contenido.
2. Social Ops genera recibo y evidencia.
3. Publicación requiere `approved=true`.
4. Ejecutor usa API oficial o sesión autenticada del navegador/Work.
5. Se captura evidencia y recibo final.

## Seguridad
- No guardar contraseñas en GitHub ni en logs.
- Reutilizar sesiones autenticadas mediante storage state cuando corresponda.
- No publicar sin aprobación explícita.
- No borrar contenido de redes sin una orden explícita independiente.

## Plataformas
- Facebook: Meta Graph API preferida; navegador como fallback.
- Instagram: Meta Graph API preferida; navegador como fallback.
- TikTok: API oficial cuando las credenciales estén disponibles; navegador como fallback.
- YouTube: YouTube Data API cuando OAuth esté disponible; navegador como fallback.

## Work / navegador autenticado
Las sesiones ya abiertas en Work deben usarse como bootstrap de autenticación. Una vez validada cada red, exportar/usar estado de sesión únicamente dentro del entorno seguro de ejecución, nunca en el repositorio.

## Criterio operativo
Social Ops se considera operativo por plataforma cuando completa: inspect -> prepare_publish -> approved publish/dry-run -> evidencia verificable.

## Estándar editorial permanente — Deep Funnel / HIR

Fuente canónica: `academy/social/CYGNUS_DEEP_FUNNEL_HIR_CONTENT_SYSTEM_V1.md`.

A partir de 2026-09-02, ningún Reel, Short, Post o carrusel se diseña como pieza aislada. Cada contenido debe registrar antes de producción:
- Interest Cluster;
- interés amplio;
- interés medio;
- intención profunda;
- problema laboral;
- resultado prometido;
- etapa del funnel;
- CTA;
- evidencia visual;
- WHO / audiencia principal;
- siguiente destino;
- métrica principal de aprendizaje.

Regla obligatoria:

`1 contenido = 1 cluster + 1 intención + 1 problema + 1 resultado + 1 etapa del funnel`.

Clusters canónicos:
- A — IA PARA EL TRABAJO.
- B — APRENDER IA.
- C — AUTOMATIZACIÓN.
- D — IA PARA NEGOCIOS.
- E — AGENTES Y SISTEMAS IA.

La coherencia semántica debe existir simultáneamente en voz/profesor, texto en pantalla, demostración visual, caption, CTA y destino. RARA debe rechazar piezas donde estas señales apunten a intenciones diferentes.

Principio de evidencia:

`Nunca decir que la IA puede hacer algo cuando podemos mostrarlo ocurriendo.`

La secuencia editorial debe mover al usuario progresivamente desde descubrimiento y problema hacia demostración, resultado, método Cygnus, autoridad, automatización/sistemas, agentes y finalmente Starter/conversión. No se debe publicar una pieza profunda de conversión antes de contar con suficiente calentamiento previo.

Medición obligatoria por profundidad:
- Top: alcance, 3s views, retención temprana.
- Mid: 50%+ playback, perfil, guardados, compartidos.
- Deep: clic web/Skool, ingreso a comunidad, inicio Starter, finalización Starter, upgrade futuro.

No declarar ganador solamente por views. La evaluación debe considerar avance profundo relativo al papel de la pieza en el funnel.

La estrategia continúa orgánica. Campañas pagadas, publicación masiva y cualquier publicación nueva continúan sujetas a autorización separada.
