# Benchmark — MoneyPrinterTurbo

Fecha: 2026-08-29
Proyecto: Cygnus Academy / ContentFlow
Referencia externa: `harry0703/MoneyPrinterTurbo`
Estado: BENCHMARK ACTIVO / NO COPIA DIRECTA

## Qué es
MoneyPrinterTurbo es una plataforma open source orientada a generar videos cortos HD de forma automatizada a partir de un tema o palabra clave. El flujo oficial cubre guion, búsqueda o generación de material visual, voz, subtítulos, música y composición final.

## Capacidades verificadas del benchmark
- Interfaces: AI Agent, WebUI, API y CLI.
- Generación automática o uso de guion personalizado.
- Formatos 9:16 y 16:9.
- Generación por lotes de varias versiones.
- Guiones multilingües.
- Múltiples TTS: Edge TTS, Azure Speech, Gemini, ElevenLabs, Fish Audio y otros.
- Subtítulos configurables.
- Música de fondo.
- Uso de assets locales y fuentes como Pexels, Pixabay y Coverr.
- Generación de video por IA mediante proveedores externos.
- Compatibilidad con múltiples LLM y gateways/model routers.
- Publicación automatizada a TikTok, Instagram y YouTube Shorts.
- Presets exportables/importables.
- Docker, WebUI y API.
- GPU opcional; útil para transcripción/local processing/batch acceleration.

## Ideas que sí debemos conservar para Cygnus/ContentFlow
1. Pipeline de video end-to-end desde tema hasta pieza lista para publicar.
2. Arquitectura desacoplada por etapas y proveedores, evitando dependencia de un único modelo.
3. Selección automática de keywords visuales a partir del guion.
4. Estrategia multi-provider para LLM, TTS, generación visual y video.
5. Producción por lotes con múltiples candidatos y selección por QA/Judge.
6. Soporte simultáneo para vertical 9:16 y horizontal 16:9.
7. Publicación multi-red como fase separada de la creación, con aprobación/política antes del publish.
8. API + WebUI + Agent, de modo que pueda integrarse en Director Orquestador y también usarse manualmente.
9. Presets reproducibles por marca/canal/campaña.
10. GPU sólo cuando aporte valor; cloud APIs para mantener costos y latencia controlados.

## Qué debemos mejorar en nuestro sistema
- No hacer publicación directa sin policy gate: usar Director + QA + aprobación humana cuando aplique.
- Mantener evidencia por asset, prompt, modelo, versión, costo y resultado.
- Integrar scoring automático de hook, legibilidad, branding, safe zones, subtítulos y CTA.
- Incorporar RARA para reparación de piezas fallidas en vez de repetir el pipeline completo.
- Añadir trazabilidad de licencias/procedencia de cada asset visual/audio.
- Enrutar por costo/calidad/disponibilidad usando Nexo/ContentFlow.
- Separar contenido orgánico, anuncios y material educativo.
- Integrar los avatares Cygnus cuando la pieza requiera profesor/avatar, sin obligar a usarlos en todo contenido.
- Añadir canary publishing y rollback/archivo cuando las plataformas lo permitan.
- Añadir analítica posterior y feedback loop para que el sistema aprenda de retención, CTR, comentarios y conversiones.

## Arquitectura objetivo inspirada en el benchmark
`topic/brief -> research -> script -> storyboard -> asset plan -> visual/video generation -> TTS -> subtitles -> music -> composition -> automated QA -> RARA remediation -> platform adaptation -> approval gate -> publish -> analytics -> learning loop`

Cada etapa debe producir evidencia estructurada y poder cambiar de proveedor sin romper el pipeline.

## Encaje con Academy
Este benchmark es especialmente relevante para:
- producción de Reels/Shorts;
- F01-F10 y futuras campañas;
- material de calentamiento de redes;
- clips derivados de clases;
- microlecciones;
- anuncios y contenido educativo;
- demostraciones automáticas de IA aplicada.

## Regla de uso
MoneyPrinterTurbo queda registrado como referencia técnica y de producto. No se copiará a ciegas. Antes de incorporar componentes, validar licencia, seguridad, dependencias, calidad, costo, mantenibilidad e integración con la arquitectura existente de ContentFlow/Director.

## Observación sobre métricas de popularidad
La captura compartida muestra `103k stars`, pero la página pública de GitHub consultada el 2026-08-29 mostraba aproximadamente `18k forks` y un contador de estrellas distinto/no equivalente a la captura. No usar la cifra de la captura como evidencia canónica de popularidad sin una comprobación adicional.