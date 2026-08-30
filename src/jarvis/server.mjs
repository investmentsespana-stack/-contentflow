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

async function openaiChat(messages) {
  const key = process.env.OPENAI_API_KEY;
  if (!key) throw new Error('OPENAI_API_KEY_missing');
  const response = await fetch('https://api.openai.com/v1/responses', {
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
  const body = await response.json();
  if (!response.ok) throw new Error(body?.error?.message || `openai_${response.status}`);
  return body.output_text || body.output?.flatMap((o) => o.content || []).map((c) => c.text).filter(Boolean).join('\n') || '';
}

async function fetchJson(url, options = {}) {
  const response = await fetch(url, options);
  const text = await response.text();
  let body;
  try { body = text ? JSON.parse(text) : {}; } catch { body = { raw: text }; }
  if (!response.ok) throw new Error(body?.error || body?.message || `http_${response.status}`);
  return body;
}

async function directorFetch(pathname, options = {}) {
  if (!DIRECTOR_BASE_URL) throw new Error('DIRECTOR_BASE_URL_missing');
  const headers = { 'content-type': 'application/json', ...(options.headers || {}) };
  if (DIRECTOR_TOKEN) headers.authorization = `Bearer ${DIRECTOR_TOKEN}`;
  return fetchJson(`${DIRECTOR_BASE_URL}${pathname}`, { ...options, headers });
}

async function supabaseRest(table, query) {
  if (!SUPABASE_URL || !SUPABASE_ACCESS_TOKEN) throw new Error('SUPABASE_runtime_credentials_missing');
  return fetchJson(`${SUPABASE_URL}/rest/v1/${table}?${query}`, {
    headers: {
      authorization: `Bearer ${SUPABASE_ACCESS_TOKEN}`,
      apikey: SUPABASE_ACCESS_TOKEN,
      accept: 'application/json'
    }
  });
}

async function realDirectorStatus() {
  if (DIRECTOR_BASE_URL) return directorFetch('/status');
  const project = encodeURIComponent(DIRECTOR_PROJECT_KEY);
  const [cycles, tasks, events] = await Promise.all([
    supabaseRest('director_cycle_runs', `select=id,status,dispatched,started_at,finished_at,pre_state,post_state,warnings&project_key=eq.${project}&order=started_at.desc&limit=1`),
    supabaseRest('contentflow_builder_backlog', `select=id,task_key,status,priority,updated_at,block_reason&project_key=eq.${project}&order=updated_at.desc&limit=100`),
    supabaseRest('director_autonomy_events', `select=id,event_type,source,outcome,finished_at,notes&project_key=eq.${project}&order=finished_at.desc&limit=20`)
  ]);
  const cycle = cycles?.[0] || null;
  const counts = {};
  for (const task of tasks || []) counts[task.status] = (counts[task.status] || 0) + 1;
  const active = (tasks || []).filter((t) => ['running', 'claimed', 'in_progress', 'dispatched'].includes(String(t.status)));
  const blocked = (tasks || []).filter((t) => ['blocked', 'failed', 'waiting'].includes(String(t.status)) || t.block_reason);
  const rara = (events || []).find((e) => String(e.source).toLowerCase().includes('rara') || String(e.event_type).toLowerCase().includes('rara')) || null;
  return {
    ok: true,
    source: 'supabase-control-plane',
    projectKey: DIRECTOR_PROJECT_KEY,
    director: cycle ? { status: cycle.status, cycleId: cycle.id, dispatched: cycle.dispatched, startedAt: cycle.started_at, finishedAt: cycle.finished_at, preState: cycle.pre_state, postState: cycle.post_state, warnings: cycle.warnings } : null,
    tasks: { totalObserved: (tasks || []).length, counts, active: active.slice(0, 20), blocked: blocked.slice(0, 20) },
    rara,
    recentEvents: events || []
  };
}

async function realDirectorCommand(command) {
  if (DIRECTOR_BASE_URL) return directorFetch('/command', { method: 'POST', body: JSON.stringify({ command, source: 'jarvis-desktop' }) });
  if (!SUPABASE_URL || !SUPABASE_ACCESS_TOKEN) throw new Error('director_runtime_not_configured');
  const normalized = command.trim().toLowerCase();
  const safeCycle = /^(revisa|revisar|continua|continúa|ejecuta|corre|run|ciclo|director)(\s|$)/i.test(normalized);
  if (!safeCycle) return { ok: false, accepted: false, error: 'command_requires_director_adapter', detail: 'La conexión directa sólo permite solicitar un ciclo seguro del Director; órdenes específicas deben entrar por el adaptador autorizado.' };
  const result = await fetchJson(`${SUPABASE_URL}/functions/v1/contentflow-director-control`, {
    method: 'POST',
    headers: { authorization: `Bearer ${SUPABASE_ACCESS_TOKEN}`, 'content-type': 'application/json' },
    body: '{}'
  });
  return { ok: Boolean(result?.ok), accepted: true, source: 'contentflow-director-control', command, result };
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);
    if (req.method === 'GET' && url.pathname === '/health') return json(res, 200, { ok: true, service: 'jarvis-desktop', openaiConfigured: Boolean(process.env.OPENAI_API_KEY), directorConfigured: Boolean(DIRECTOR_BASE_URL || (SUPABASE_URL && SUPABASE_ACCESS_TOKEN)), directorMode: DIRECTOR_BASE_URL ? 'adapter' : (SUPABASE_URL && SUPABASE_ACCESS_TOKEN ? 'supabase-control-plane' : 'none'), projectKey: DIRECTOR_PROJECT_KEY });
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
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' }); return res.end(html);
    }
    return json(res, 404, { error: 'not_found' });
  } catch (error) {
    const code = error?.message === 'payload_too_large' ? 413 : 500;
    return json(res, code, { error: String(error?.message || error) });
  }
});

server.listen(PORT, HOST, () => console.log(`Jarvis Desktop: http://${HOST}:${PORT}`));
