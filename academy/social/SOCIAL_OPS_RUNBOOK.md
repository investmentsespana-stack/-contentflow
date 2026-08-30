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
