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
    headers: {
      authorization: `Bearer ${key}`,
      'content-type': 'application/json'
    },
    body: JSON.stringify({
      model: OPENAI_MODEL,
      store: false,
      input: [
        {
          role: 'system',
          content: [
            {
              type: 'input_text',
              text: 'Eres Jarvis Desktop, asistente operativo en español. Sé breve, claro y orientado a ejecución. Distingue conversación de órdenes al Director. No inventes estado de tareas ni ejecuciones.'
            }
          ]
        },
        ...messages.map((m) => ({
          role: m.role === 'assistant' ? 'assistant' : 'user',
          content: [{ type: 'input_text', text: String(m.content || '') }]
        }))
      ]
    })
  });
  const body = await response.json();
  if (!response.ok) throw new Error(body?.error?.message || `openai_${response.status}`);
  return body.output_text || body.output?.flatMap((o) => o.content || []).map((c) => c.text).filter(Boolean).join('\n') || '';
}

async function directorFetch(pathname, options = {}) {
  if (!DIRECTOR_BASE_URL) throw new Error('DIRECTOR_BASE_URL_missing');
  const headers = { 'content-type': 'application/json', ...(options.headers || {}) };
  if (DIRECTOR_TOKEN) headers.authorization = `Bearer ${DIRECTOR_TOKEN}`;
  const response = await fetch(`${DIRECTOR_BASE_URL}${pathname}`, { ...options, headers });
  const text = await response.text();
  let body;
  try { body = text ? JSON.parse(text) : {}; } catch { body = { raw: text }; }
  if (!response.ok) throw new Error(body?.error || body?.message || `director_${response.status}`);
  return body;
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);

    if (req.method === 'GET' && url.pathname === '/health') {
      return json(res, 200, {
        ok: true,
        service: 'jarvis-desktop',
        openaiConfigured: Boolean(process.env.OPENAI_API_KEY),
        directorConfigured: Boolean(DIRECTOR_BASE_URL)
      });
    }

    if (req.method === 'POST' && url.pathname === '/api/chat') {
      const body = await readJson(req);
      const messages = Array.isArray(body.messages) ? body.messages.slice(-24) : [];
      if (!messages.length) return json(res, 400, { error: 'messages_required' });
      const reply = await openaiChat(messages);
      return json(res, 200, { reply, model: OPENAI_MODEL });
    }

    if (req.method === 'GET' && url.pathname === '/api/director/status') {
      const status = await directorFetch('/status');
      return json(res, 200, status);
    }

    if (req.method === 'POST' && url.pathname === '/api/director/command') {
      const body = await readJson(req);
      if (!String(body.command || '').trim()) return json(res, 400, { error: 'command_required' });
      const result = await directorFetch('/command', {
        method: 'POST',
        body: JSON.stringify({ command: String(body.command), source: 'jarvis-desktop' })
      });
      return json(res, 200, result);
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

server.listen(PORT, HOST, () => {
  console.log(`Jarvis Desktop: http://${HOST}:${PORT}`);
});
