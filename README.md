# ContentFlow

Repositorio maestro de ContentFlow.

## Arquitectura

- GitHub: fuente de verdad del código, historial, PRs y CI.
- Vercel: despliegue web/runtime.
- Supabase: base de datos, Edge Functions, estado y memoria del Director.
- NexoRouter: gateway de modelos/agentes.

## Producción

- Vercel project: `contentflow-ai`
- Production URL: `https://contentflow-ai-tan.vercel.app`
- Supabase project: `koqpyfvnprmirqviafzq`

## QA

La matriz de navegador usa Playwright en GitHub Actions con Chromium, Firefox y WebKit. El objetivo inmediato es obtener evidencia real para `panel_qa_v1_browser`.

## Seguridad

Nunca subir secretos, API keys, service-role keys ni credenciales. Usar GitHub Actions Secrets y variables de entorno del proveedor.
