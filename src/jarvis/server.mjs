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
const BUILD = '2026-08-31-multiproject-router-v4';
const stateDir = path.join(os.homedir(), '.jarvis');
const deviceTokenFile = path.join(stateDir, 'director-device-token');

const PROJECTS = {
  contentflow: { key:'contentflow', name:'ContentFlow / Director', aliases:['contentflow','director','orquestador'] },
  avatar: { key:'avatar-platform-v1', name:'Avatar', aliases:['avatar','avatar platform','proyecto avatar'] },
  academy: { key:'agent-academy-platform-v1', name:'Cygnus Academy / Skool', aliases:['academy','academia','skool','cygnus','cygnus academy','proyecto skool'] },
};
let activeProject = 'contentflow';
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
  const transcript = messages.map(m => `${m.role === 'assistant' ? 'Jarvis' : 'Usuario'}: ${String(m.content || '')}`).join('\n');
  const body = await fetchJson('https://api.openai.com/v1/responses', {
    method:'POST', headers:{authorization:`Bearer ${runtimeOpenAIKey}`,'content-type':'application/json'},
    body:JSON.stringify({model:OPENAI_MODEL,store:false,instructions:'Eres Jarvis Desktop, asistente operativo en español. Sé breve, claro y orientado a ejecución. No inventes estado de tareas ni ejecuciones. Si el usuario habla de proyectos, recuerda que las operaciones reales de ContentFlow, Avatar y Cygnus Academy se enrutan localmente antes de llegar a ti. Responde únicamente al último mensaje del Usuario.',input:transcript})
  });
  return body.output_text || body.output?.flatMap(o=>o.content||[]).map(c=>c.text).filter(Boolean).join('\n') || '';
}
function resolveProjectId(value='') {
  const raw=String(value).trim().toLowerCase();
  for (const [id,p] of Object.entries(PROJECTS)) if (id===raw || p.key===raw || p.aliases.some(a=>raw===a || raw.includes(a))) return id;
  return null;
}
function projectInfo(id=activeProject) { return PROJECTS[id] || PROJECTS.contentflow; }
async function bridge(action, extra={}) {
  if (!directorDeviceToken) throw new Error('DIRECTOR_pairing_required');
  return fetchJson(`${SUPABASE_URL}/functions/v1/jarvis-director-bridge`, {
    method:'POST', headers:{authorization:`Bearer ${directorDeviceToken}`,apikey:SUPABASE_PUBLISHABLE_KEY,'content-type':'application/json'},
    body:JSON.stringify({action,project_key:projectInfo(activeProject).key,...extra})
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
function stripWakeWord(text='') { return String(text).trim().replace(/^jarvis\s*[,;:]?\s*/i,'').trim(); }
function detectProject(text='') {
  const clean=stripWakeWord(text).toLowerCase();
  if (/\bavatar\b/i.test(clean)) return 'avatar';
  if (/\b(academia|academy|skool|cygnus)\b/i.test(clean)) return 'academy';
  if (/\b(contentflow|director|orquestador)\b/i.test(clean)) return 'contentflow';
  return null;
}
function classifyJarvisIntent(text='') {
  const clean=stripWakeWord(text).toLowerCase();
  const project=detectProject(clean);
  const selectIntent=project && /(entra|entrar|abre|abrir|cambia|cambiar|ve\s+a|vamos\s+a|selecciona|seleccionar|proyecto)/i.test(clean);
  const cycleIntent=(project || activeProject) && /(ejecuta|ejecutar|corre|correr|haz|hacer|inicia|iniciar|arranca|arrancar|contin[uú]a|revisa|ciclo|run|procesa|trabaja)/i.test(clean) && /(proyecto|director|avatar|academia|academy|skool|cygnus|contentflow|ciclo|tarea)/i.test(clean);
  const statusIntent=(project || activeProject) && /(estado|status|conectad|conexi[oó]n|c[oó]mo va|c[oó]mo est[aá]|qu[eé] pasa|reporte|reporta|tareas|avance)/i.test(clean);
  if (selectIntent) return {type:'project_select',project,clean};
  if (cycleIntent) return {type:'project_cycle',project:project||activeProject,clean};
  if (statusIntent && (project || /proyecto|director|tareas|avance|estado|reporte/i.test(clean))) return {type:'project_status',project:project||activeProject,clean};
  return {type:'chat',clean};
}
async function jarvisRoute(text, messages=[]) {
  const intent=classifyJarvisIntent(text);
  if (intent.type==='project_select') {
    const p=projectInfo(intent.project); const selected=await bridge('project_select',{project_key:p.key}); activeProject=intent.project;
    return {type:'project_select',reply:`Proyecto ${p.name} conectado. Ya puedo consultar su estado y ejecutar sus ciclos disponibles.`,project:selected};
  }
  if (intent.type==='project_status') {
    const p=projectInfo(intent.project); const status=await bridge('project_status',{project_key:p.key});
    return {type:'project_status',reply:`${p.name} conectado. Estado actualizado.`,project:status};
  }
  if (intent.type==='project_cycle') {
    const p=projectInfo(intent.project); const result=await bridge('project_cycle',{project_key:p.key});
    return {type:'project_cycle',reply:result?.ok?`Ciclo de ${p.name} solicitado correctamente.`:`${p.name} recibió la solicitud, pero reportó un problema.`,project:result};
  }
  const safeMessages=Array.isArray(messages)&&messages.length?messages:[{role:'user',content:text}];
  return {type:'chat',reply:await openaiChat(safeMessages),model:OPENAI_MODEL};
}
function healthState(){const p=projectInfo();return {ok:true,service:'jarvis-desktop',build:BUILD,openaiConfigured:Boolean(runtimeOpenAIKey),directorConfigured:Boolean(directorDeviceToken),directorMode:directorDeviceToken?'paired-device':'pairing-required',activeProject:{id:activeProject,key:p.key,name:p.name},availableProjects:Object.entries(PROJECTS).map(([id,v])=>({id,key:v.key,name:v.name})),openaiModel:OPENAI_MODEL};}

const server=http.createServer(async(req,res)=>{try{
  const url=new URL(req.url||'/',`http://${req.headers.host||'localhost'}`);
  if(req.method==='GET'&&url.pathname==='/health') return json(res,200,healthState());
  if(req.method==='POST'&&url.pathname==='/api/setup/openai'){const b=await readJson(req); if(!String(b.openaiApiKey||'').trim()) return json(res,400,{error:'openai_key_required'}); runtimeOpenAIKey=String(b.openaiApiKey).trim(); return json(res,200,{ok:true,health:healthState()});}
  if(req.method==='POST'&&url.pathname==='/api/setup/pair'){const b=await readJson(req); await pairDirector(b.pairingCode); return json(res,200,{ok:true,health:healthState()});}
  if(req.method==='POST'&&url.pathname==='/api/chat'){const b=await readJson(req); const messages=Array.isArray(b.messages)?b.messages.slice(-24):[]; if(!messages.length)return json(res,400,{error:'messages_required'}); return json(res,200,{reply:await openaiChat(messages),model:OPENAI_MODEL});}
  if(req.method==='POST'&&url.pathname==='/api/jarvis'){const b=await readJson(req); const text=String(b.text||'').trim(); const messages=Array.isArray(b.messages)?b.messages.slice(-24):[]; if(!text)return json(res,400,{error:'text_required'}); return json(res,200,await jarvisRoute(text,messages));}
  if(req.method==='GET'&&url.pathname==='/api/projects') return json(res,200,await bridge('projects'));
  if(req.method==='GET'&&url.pathname==='/api/director/status') return json(res,200,await bridge('project_status',{project_key:'contentflow'}));
  if(req.method==='POST'&&url.pathname==='/api/director/command'){const result=await bridge('project_cycle',{project_key:'contentflow'}); return json(res,200,result);}
  if(req.method==='GET'&&(url.pathname==='/'||url.pathname==='/index.html')){const html=await readFile(path.join(__dirname,'ui.html'),'utf8'); res.writeHead(200,{'content-type':'text/html; charset=utf-8','cache-control':'no-store'}); return res.end(html);}
  return json(res,404,{error:'not_found'});
}catch(error){const status=error?.message==='payload_too_large'?413:(Number.isInteger(error?.status)?error.status:500); return json(res,status,{error:String(error?.message||error),status,details:error?.apiBody||undefined});}});
server.listen(PORT,HOST,()=>console.log(`Jarvis Desktop: http://${HOST}:${PORT} · ${BUILD}`));
