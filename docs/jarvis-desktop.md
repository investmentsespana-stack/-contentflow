# Jarvis Desktop MVP

Jarvis Desktop es una capa local de mando para conversar con OpenAI y enviar instrucciones al Director/Orquestador existente de ContentFlow sin duplicar su lógica.

## Arranque local

Requiere Node.js 18+.

```bash
export OPENAI_API_KEY="..."
export OPENAI_MODEL="gpt-5"
export DIRECTOR_BASE_URL="http://127.0.0.1:8787"
# opcional, si el Director exige bearer token
export DIRECTOR_TOKEN="..."
node src/jarvis/server.mjs
```

Abrir `http://127.0.0.1:4317`.

Por defecto el servidor escucha únicamente en `127.0.0.1`; no se expone a la LAN. Para cambiar puerto use `JARVIS_PORT`. No guardar claves en `ui.html`, repositorio ni localStorage.

## Contrato mínimo del adaptador Director

Jarvis no reemplaza al Director. Espera que el runtime del Director exponga dos rutas configurables bajo `DIRECTOR_BASE_URL`:

- `GET /status`: devuelve JSON con estado, trabajadores, tareas o métricas disponibles.
- `POST /command`: recibe `{ "command": "...", "source": "jarvis-desktop" }` y devuelve JSON con el recibo/resultado de aceptación.

Si el runtime actual usa otro transporte, implementar un adaptador pequeño detrás de estas dos rutas manteniendo intacto el contrato interno del Director.

## Seguridad

- `OPENAI_API_KEY` y `DIRECTOR_TOKEN` viven sólo en variables de entorno del proceso servidor.
- La llamada OpenAI usa `store: false`.
- No hay endpoint genérico de shell, SSH ni ejecución arbitraria en Jarvis.
- El Director sigue siendo responsable de autorización, guardrails, RARA, recuperación y evidencia.
- Las órdenes no se marcan como ejecutadas por Jarvis: la UI muestra únicamente lo que devuelva el Director real.

## Voz

El MVP usa Web Speech Recognition cuando está disponible en el navegador para dictado. Una segunda fase puede cambiar el canal de voz a OpenAI Realtime sin alterar el contrato con el Director.

## Siguiente integración

Conectar el adaptador real del runtime del Director y mapear en `/status` las métricas de trabajadores activos, tareas en curso, bloqueos, RARA y uso GPU. Después añadir notificaciones y voz full-duplex.