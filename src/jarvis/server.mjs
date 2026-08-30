import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.JARVIS_PORT || 4317);
const HOST = process.env.JARVIS_HOST || '127.0.0.1';
const OPENAI_MODEL = process.env.OPENAI_MODEL || 'gpt-5';
const DIRECTOR_BASE_URL = (process.env.DIRECTOR_BASE_URL || '').replace(/\/$/, '');
const DIRECTOR_TOKEN = process.env.DIRECTOR_TOKEN || '';
const SUPABASE_URL = (process.env.SUPABASE_URL || '').replace(/\/$/, '');
const SUPABASE_ACCESS_TOKEN = process.env.SUPABASE_ACCESS_TOKEN || '';
const DIRECTOR_PROJECT_KEY = process.env.DIRECTOR_PROJECT_KEY || 'contentflow';

function json(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
  res.end(JSON.stringify(body));
}

async function readJson(req) {
  let data = '';
  for await (const chunk of req) {
    data += chunk;
    if (data.length > 1_000_000) throw new Error('payload_too_large');
  }
  return data ? JSON.parse(data) : {};
}

async function fetchJson(url, options = {}) {
  const response = await fetch(url, options);
  const text = await response.text();
  let body;
  try { body = text ? JSON.parse(text) : {}; } catch { body = { raw: text }; }
  if (!response.ok) throw new Error(body?.error || body?.message || `http_${response.status}`);
  return body;
}

async function openaiChat(messages) {
  const key = process.env.OPENAI_API_KEY;
  if (!key) throw new Error('OPENAI_API_KEY_missing');
  const body = await fetchJson('https://api.openai.com/v1/responses', {
    method: 'POST',
    headers: { authorization: `Bearer ${key}`, 'content-type': 'application/json' },
    body: JSON.stringify({
      model: OPENAI_MODEL,
      store: false,
      input: [
        { role: 'system', content: [{ type: 'input_text', text: 'Eres Jarvis Desktop, asistente operativo en español. Sé breve, claro y orientado a ejecución. Distingue conversación de órdenes al Director. No inventes estado de tareas ni ejecuciones.' }] },
        ...messages.map((m) => ({ role: m.role === 'assistant' ? 'assistant' : 'user', content: [{ type: 'input_text', text: String(m.content || '') }] }))
      ]
    })
  });
  return body.output_text || body.output?.flatMap((o) => o.content || []).map((c) => c.text).filter(Boolean).join('\n') || '';
}

async function directorFetch(pathname, options = {}) {
  if (!DIRECTOR_BASE_URL) throw new Error('DIRECTOR_BASE_URL_missing');
  const headers = { 'content-type': 'application/json', ...(options.headers || {}) };
  if (DIRECTOR_TOKEN) headers.authorization = `Bearer ${DIRECTOR_TOKEN}`;
  return fetchJson(`${DIRECTOR_BASE_URL}${pathname}`, { ...options, headers });
}

async function bridge(action) {
  if (!SUPABASE_URL || !SUPABASE_ACCESS_TOKEN) throw new Error('SUPABASE_runtime_credentials_missing');
  return fetchJson(`${SUPABASE_URL}/functions/v1/jarvis-director-bridge`, {
    method: 'POST',
    headers: { authorization: `Bearer ${SUPABASE_ACCESS_TOKEN}`, 'content-type': 'application/json' },
    body: JSON.stringify({ action, project_key: DIRECTOR_PROJECT_KEY })
  });
}

async function realDirectorStatus() {
  if (DIRECTOR_BASE_URL) return directorFetch('/status');
  return bridge('status');
}

async function realDirectorCommand(command) {
  if (DIRECTOR_BASE_URL) return directorFetch('/command', { method: 'POST', body: JSON.stringify({ command, source: 'jarvis-desktop' }) });
  const normalized = command.trim().toLowerCase();
  const safeCycle = /^(revisa|revisar|continua|continúa|ejecuta|corre|run|ciclo|director)(\s|$)/i.test(normalized);
  if (!safeCycle) return { ok: false, accepted: false, error: 'command_requires_director_adapter', detail: 'El bridge autenticado sólo permite solicitar un ciclo seguro del Director. Las órdenes específicas se mantienen detrás del adaptador autorizado.' };
  const result = await bridge('cycle');
  return { ok: Boolean(result?.ok), accepted: true, source: 'jarvis-director-bridge', command, result };
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);
    if (req.method === 'GET' && url.pathname === '/health') return json(res, 200, {
      ok: true,
      service: 'jarvis-desktop',
      openaiConfigured: Boolean(process.env.OPENAI_API_KEY),
      directorConfigured: Boolean(DIRECTOR_BASE_URL || (SUPABASE_URL && SUPABASE_ACCESS_TOKEN)),
      directorMode: DIRECTOR_BASE_URL ? 'adapter' : (SUPABASE_URL && SUPABASE_ACCESS_TOKEN ? 'authenticated-supabase-bridge' : 'none'),
      projectKey: DIRECTOR_PROJECT_KEY
    });
    if (req.method === 'POST' && url.pathname === '/api/chat') {
      const body = await readJson(req); const messages = Array.isArray(body.messages) ? body.messages.slice(-24) : [];
      if (!messages.length) return json(res, 400, { error: 'messages_required' });
      return json(res, 200, { reply: await openaiChat(messages), model: OPENAI_MODEL });
    }
    if (req.method === 'GET' && url.pathname === '/api/director/status') return json(res, 200, await realDirectorStatus());
    if (req.method === 'POST' && url.pathname === '/api/director/command') {
      const body = await readJson(req); const command = String(body.command || '').trim();
      if (!command) return json(res, 400, { error: 'command_required' });
      const result = await realDirectorCommand(command);
      return json(res, result?.accepted === false ? 409 : 200, result);
    }
    if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) {
      const html = await readFile(path.join(__dirname, 'ui.html'), 'utf8');
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
      return res.end(html);
    }
    return json(res, 404, { error: 'not_found' });
  } catch (error) {
    const code = error?.message === 'payload_too_large' ? 413 : 500;
    return json(res, code, { error: String(error?.message || error) });
  }
});

server.listen(PORT, HOST, () => console.log(`Jarvis Desktop: http://${HOST}:${PORT}`));
