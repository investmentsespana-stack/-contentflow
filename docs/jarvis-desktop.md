# Jarvis Desktop MVP

Jarvis Desktop es una capa local de mando para conversar con OpenAI y operar el Director/Orquestador existente de ContentFlow sin duplicar su lógica.

## Arranque local

Requiere Node.js 18+.

```bash
export OPENAI_API_KEY="..."
export OPENAI_MODEL="gpt-5"

# Modo recomendado cuando exista adaptador dedicado:
export DIRECTOR_BASE_URL="http://127.0.0.1:8787"
export DIRECTOR_TOKEN="..." # opcional

# Modo directo al control plane real de ContentFlow:
export SUPABASE_URL="https://<project-ref>.supabase.co"
export SUPABASE_ACCESS_TOKEN="..." # credencial privada del proceso local; nunca en navegador
export DIRECTOR_PROJECT_KEY="contentflow"

node src/jarvis/server.mjs
```

Abrir `http://127.0.0.1:4317`.

El servidor escucha por defecto únicamente en `127.0.0.1`. Las credenciales viven sólo en el proceso servidor; no deben guardarse en `ui.html`, repositorio ni localStorage.

## Integración real con el Director

Jarvis usa dos modos, en este orden:

1. `DIRECTOR_BASE_URL`: adaptador dedicado con `GET /status` y `POST /command`.
2. Si no existe adaptador, usa el control plane Supabase real. Lee `director_cycle_runs`, backlog y `director_autonomy_events`, y puede solicitar un ciclo seguro mediante la Edge Function existente `contentflow-director-control`.

El modo directo no convierte a Jarvis en un shell. Sólo acepta órdenes generales de ciclo como revisar/continuar/ejecutar. Una orden específica o destructiva se rechaza hasta que exista un adaptador autorizado que preserve los guardrails del Director.

## Estado mostrado

`/api/director/status` devuelve estado del último ciclo, tareas observadas por estado, tareas activas, bloqueadas, último evento RARA y eventos recientes. No se fabrican trabajadores, bloqueos ni porcentajes.

## Seguridad

- `OPENAI_API_KEY`, `DIRECTOR_TOKEN` y `SUPABASE_ACCESS_TOKEN` viven sólo en variables de entorno del proceso servidor.
- La llamada OpenAI usa `store: false`.
- No hay endpoint genérico de shell, SSH ni ejecución arbitraria.
- El Director sigue siendo responsable de autorización, guardrails, RARA, recuperación y evidencia.
- Jarvis muestra únicamente resultados devueltos por el runtime real.

## Voz

El MVP usa Web Speech Recognition cuando está disponible para dictado. La siguiente fase puede cambiar el canal de voz a OpenAI Realtime sin alterar el contrato con el Director.

## GPU

La conexión Director/Jarvis no requiere GPU. La GPU se reserva para cargas que realmente la aprovechen, como Avatar/voz/modelos locales, evitando consumo ocioso.
