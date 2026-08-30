#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if ! command -v node >/dev/null 2>&1; then
  echo "Node.js no está instalado. Instala Node.js 22 LTS y vuelve a ejecutar este archivo." >&2
  exit 1
fi
export JARVIS_HOST="127.0.0.1"
export JARVIS_PORT="${JARVIS_PORT:-4317}"
URL="http://127.0.0.1:${JARVIS_PORT}"
if command -v open >/dev/null 2>&1; then open "$URL" >/dev/null 2>&1 || true; elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$URL" >/dev/null 2>&1 || true; fi
exec node src/jarvis/server.mjs
