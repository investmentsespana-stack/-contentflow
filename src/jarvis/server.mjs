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
const SUPABASE_URL = (process.env.SUPABASE_URL || 'https://koqpyfvnprmirqviafzq.supabase.co').replace(/\/$/, '');
const SUPABASE_PUBLISHABLE_KEY = process.env.SUPABASE_PUBLISHABLE_KEY || 'sb_publishable_KTxRW4wca-AcvP2tDve6Lw_PDI7WG_8';
const DIRECTOR_PROJECT_KEY = process.env.DIRECTOR_PROJECT_KEY || 'contentflow';

let runtimeOpenAIKey = process.env.OPENAI_API_KEY || '';
let supabaseAccessToken = process.env.SUPABASE_ACCESS_TOKEN || '';
let supabaseRefreshToken = '';
let supabaseExpiresAt = 0;

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
  if (!response.ok) throw new Error(body?.error_description || body?.error || body?.message || `http_${response.status}`);
  return body;
}

async function openaiChat(messages) {
  if (!runtimeOpenAIKey) throw new Error('OPENAI_API_KEY_missing');
  const body = await fetchJson('https://api.openai.com/v1/responses', {
    method: 'POST',
    headers: { authorization: `Bearer ${runtimeOpenAIKey}`, 'content-type': 'application/json' },
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

async function loginSupabase(email, password) {
  const session = await fetchJson(`${SUPABASE_URL}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: { apikey: SUPABASE_PUBLISHABLE_KEY, 'content-type': 'application/json' },
    body: JSON.stringify({ email, password })
  });
  supabaseAccessToken = String(session.access_token || '');
  supabaseRefreshToken = String(session.refresh_token || '');
  supabaseExpiresAt = Date.now() + Math.max(60, Number(session.expires_in || 3600) - 60) * 1000;
  if (!supabaseAccessToken) throw new Error('supabase_access_token_missing');
  return { user: session.user ? { id: session.user.id, email: session.user.email } : null, expiresIn: Number(session.expires_in || 0) };
}

async function ensureSupabaseToken() {
  if (supabaseAccessToken && (!supabaseExpiresAt || Date.now() < supabaseExpiresAt)) return supabaseAccessToken;
  if (!supabaseRefreshToken) throw new Error('SUPABASE_login_required');
  const session = await fetchJson(`${SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`, {
    method: 'POST',
    headers: { apikey: SUPABASE_PUBLISHABLE_KEY, 'content-type': 'application/json' },
    body: JSON.stringify({ refresh_token: supabaseRefreshToken })
  });
  supabaseAccessToken = String(session.access_token || '');
  supabaseRefreshToken = String(session.refresh_token || supabaseRefreshToken);
  supabaseExpiresAt = Date.now() + Math.max(60, Number(session.expires_in || 3600) - 60) * 1000;
  return supabaseAccessToken;
}

async function bridge(action) {
  const token = await ensureSupabaseToken();
  return fetchJson(`${SUPABASE_URL}/functions/v1/jarvis-director-bridge`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, apikey: SUPABASE_PUBLISHABLE_KEY, 'content-type': 'application/json' },
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

function healthState() {
  return {
    ok: true,
    service: 'jarvis-desktop',
    openaiConfigured: Boolean(runtimeOpenAIKey),
    directorConfigured: Boolean(DIRECTOR_BASE_URL || supabaseAccessToken),
    directorMode: DIRECTOR_BASE_URL ? 'adapter' : (supabaseAccessToken ? 'authenticated-supabase-bridge' : 'login-required'),
    supabaseLoginRequired: !DIRECTOR_BASE_URL && !supabaseAccessToken,
    projectKey: DIRECTOR_PROJECT_KEY
  };
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);
    if (req.method === 'GET' && url.pathname === '/health') return json(res, 200, healthState());
    if (req.method === 'POST' && url.pathname === '/api/setup') {
      const body = await readJson(req);
      if (String(body.openaiApiKey || '').trim()) runtimeOpenAIKey = String(body.openaiApiKey).trim();
      let login = null;
      if (String(body.email || '').trim() || String(body.password || '')) {
        if (!String(body.email || '').trim() || !String(body.password || '')) return json(res, 400, { error: 'email_and_password_required' });
        login = await loginSupabase(String(body.email).trim(), String(body.password));
      }
      return json(res, 200, { ok: true, health: healthState(), login });
    }
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
