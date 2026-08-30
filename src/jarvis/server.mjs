import http from 'node:http';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import os from 'node:os';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.JARVIS_PORT || 4317);
const HOST = process.env.JARVIS_HOST || '127.0.0.1';
const OPENAI_MODEL = process.env.OPENAI_MODEL || 'gpt-5.6-sol';
const SUPABASE_URL = (process.env.SUPABASE_URL || 'https://koqpyfvnprmirqviafzq.supabase.co').replace(/\/$/, '');
const SUPABASE_PUBLISHABLE_KEY = process.env.SUPABASE_PUBLISHABLE_KEY || 'sb_publishable_KTxRW4wca-AcvP2tDve6Lw_PDI7WG_8';
const DIRECTOR_PROJECT_KEY = process.env.DIRECTOR_PROJECT_KEY || 'contentflow';
const stateDir = path.join(os.homedir(), '.jarvis');
const deviceTokenFile = path.join(stateDir, 'director-device-token');

let runtimeOpenAIKey = process.env.OPENAI_API_KEY || '';
let directorDeviceToken = process.env.JARVIS_DIRECTOR_DEVICE_TOKEN || '';
try { if (!directorDeviceToken) directorDeviceToken = (await readFile(deviceTokenFile, 'utf8')).trim(); } catch {}

function json(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
  res.end(JSON.stringify(body));
}
async function readJson(req) {
  let data=''; for await (const chunk of req) { data += chunk; if (data.length > 1_000_000) throw new Error('payload_too_large'); }
  return data ? JSON.parse(data) : {};
}
function apiErrorMessage(body, status) {
  const candidate = body?.error?.message ?? body?.error_description ?? body?.message ?? body?.error ?? body?.raw;
  if (typeof candidate === 'string' && candidate.trim()) return candidate.trim();
  try { if (candidate != null) return JSON.stringify(candidate); } catch {}
  return `http_${status}`;
}
async function fetchJson(url, options={}) {
  const response = await fetch(url, options); const text = await response.text();
  let body; try { body = text ? JSON.parse(text) : {}; } catch { body = {raw:text}; }
  if (!response.ok) { const error = new Error(apiErrorMessage(body, response.status)); error.status = response.status; error.apiBody = body; throw error; }
  return body;
}
async function openaiChat(messages) {
  if (!runtimeOpenAIKey) throw new Error('OPENAI_API_KEY_missing');
  const body = await fetchJson('https://api.openai.com/v1/responses', {
    method:'POST', headers:{authorization:`Bearer ${runtimeOpenAIKey}`,'content-type':'application/json'},
    body:JSON.stringify({model:OPENAI_MODEL,store:false,input:[
      {role:'system',content:[{type:'input_text',text:'Eres Jarvis Desktop, asistente operativo en español. Sé breve, claro y orientado a ejecución. Distingue conversación de órdenes al Director. No inventes estado de tareas ni ejecuciones.'}]},
      ...messages.map(m=>({
        role:m.role==='assistant'?'assistant':'user',
        content:[{type:m.role==='assistant'?'output_text':'input_text',text:String(m.content||'')}]
      }))
    ]})
  });
  return body.output_text || body.output?.flatMap(o=>o.content||[]).map(c=>c.text).filter(Boolean).join('\n') || '';
}
async function bridge(action, extra={}) {
  if (!directorDeviceToken) throw new Error('DIRECTOR_pairing_required');
  return fetchJson(`${SUPABASE_URL}/functions/v1/jarvis-director-bridge`, {
    method:'POST', headers:{authorization:`Bearer ${directorDeviceToken}`,apikey:SUPABASE_PUBLISHABLE_KEY,'content-type':'application/json'},
    body:JSON.stringify({action,project_key:DIRECTOR_PROJECT_KEY,...extra})
  });
}
async function pairDirector(code) {
  const result = await fetchJson(`${SUPABASE_URL}/functions/v1/jarvis-director-bridge`, {
    method:'POST', headers:{apikey:SUPABASE_PUBLISHABLE_KEY,'content-type':'application/json'},
    body:JSON.stringify({action:'pair',pairing_code:String(code||'').trim()})
  });
  directorDeviceToken = String(result.device_token||'');
  if (!directorDeviceToken) throw new Error('device_token_missing');
  await mkdir(stateDir,{recursive:true}); await writeFile(deviceTokenFile,directorDeviceToken,{encoding:'utf8',mode:0o600});
  return {ok:true};
}
async function realDirectorCommand(command) {
  const normalized=command.trim().toLowerCase();
  const safeCycle=/^(revisa|revisar|continua|continúa|ejecuta|corre|run|ciclo|director)(\s|$)/i.test(normalized);
  if(!safeCycle) return {ok:false,accepted:false,error:'command_requires_director_adapter',detail:'Por seguridad, este bridge sólo permite solicitar un ciclo seguro del Director.'};
  const result=await bridge('cycle'); return {ok:Boolean(result?.ok),accepted:true,source:'jarvis-director-bridge',command,result};
}
function healthState(){return {ok:true,service:'jarvis-desktop',openaiConfigured:Boolean(runtimeOpenAIKey),directorConfigured:Boolean(directorDeviceToken),directorMode:directorDeviceToken?'paired-device':'pairing-required',projectKey:DIRECTOR_PROJECT_KEY,openaiModel:OPENAI_MODEL};}

const server=http.createServer(async(req,res)=>{try{
  const url=new URL(req.url||'/',`http://${req.headers.host||'localhost'}`);
  if(req.method==='GET'&&url.pathname==='/health') return json(res,200,healthState());
  if(req.method==='POST'&&url.pathname==='/api/setup/openai'){const b=await readJson(req); if(!String(b.openaiApiKey||'').trim()) return json(res,400,{error:'openai_key_required'}); runtimeOpenAIKey=String(b.openaiApiKey).trim(); return json(res,200,{ok:true,health:healthState()});}
  if(req.method==='POST'&&url.pathname==='/api/setup/pair'){const b=await readJson(req); await pairDirector(b.pairingCode); return json(res,200,{ok:true,health:healthState()});}
  if(req.method==='POST'&&url.pathname==='/api/chat'){const b=await readJson(req); const messages=Array.isArray(b.messages)?b.messages.slice(-24):[]; if(!messages.length)return json(res,400,{error:'messages_required'}); return json(res,200,{reply:await openaiChat(messages),model:OPENAI_MODEL});}
  if(req.method==='GET'&&url.pathname==='/api/director/status') return json(res,200,await bridge('status'));
  if(req.method==='POST'&&url.pathname==='/api/director/command'){const b=await readJson(req); const command=String(b.command||'').trim(); if(!command)return json(res,400,{error:'command_required'}); const result=await realDirectorCommand(command); return json(res,result?.accepted===false?409:200,result);}
  if(req.method==='GET'&&(url.pathname==='/'||url.pathname==='/index.html')){const html=await readFile(path.join(__dirname,'ui.html'),'utf8'); res.writeHead(200,{'content-type':'text/html; charset=utf-8','cache-control':'no-store'}); return res.end(html);}
  return json(res,404,{error:'not_found'});
}catch(error){const status=error?.message==='payload_too_large'?413:(Number.isInteger(error?.status)?error.status:500); return json(res,status,{error:String(error?.message||error),status,details:error?.apiBody||undefined});}});
server.listen(PORT,HOST,()=>console.log(`Jarvis Desktop: http://${HOST}:${PORT}`));
