import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';

const port=44317;
const base=`http://127.0.0.1:${port}`;
async function waitForHealth(){for(let i=0;i<50;i++){try{const r=await fetch(`${base}/health`);if(r.ok)return r}catch{}await new Promise(r=>setTimeout(r,100))}throw new Error('server did not start')}
async function classify(text){const r=await fetch(`${base}/api/classify`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({text})});assert.equal(r.status,200);return r.json()}

test('Jarvis Desktop boots fail-closed and enforces explicit execution',async t=>{
 const child=spawn(process.execPath,['src/jarvis/server.mjs'],{env:{...process.env,JARVIS_PORT:String(port),JARVIS_HOST:'127.0.0.1',OPENAI_API_KEY:'',JARVIS_DIRECTOR_DEVICE_TOKEN:''},stdio:['ignore','pipe','pipe']});
 t.after(()=>child.kill('SIGTERM'));
 const response=await waitForHealth();
 const body=await response.json();
 assert.equal(body.ok,true);
 assert.equal(body.service,'jarvis-desktop');
 assert.equal(body.openaiConfigured,false);
 assert.equal(body.directorConfigured,false);
 assert.equal(body.directorMode,'pairing-required');
 assert.equal(body.active.projectKey,'contentflow');
 assert.match(body.build,/conversation-router-v5\.1$/);

 const cases=[
  ['¿Qué está haciendo el Director?','project_information',false],
  ['Dame reporte del Director','project_information',false],
  ['¿Cómo va Avatar?','project_information',false],
  ['Reporte de Skool','project_information',false],
  ['Hablar con Sol','switch_sol',false],
  ['Pásame con el Director','switch_project',false],
  ['Entra a Avatar','switch_project',false],
  ['Hablar con Skool','switch_project',false],
  ['Ejecuta un ciclo del Director','project_cycle',true],
  ['Corre un run de Avatar','project_cycle',true],
  ['Arranca un ciclo de Skool','project_cycle',true],
  ['Revisa el Director','chat',false],
  ['Continúa con Avatar','chat',false],
  ['Ejecuta tareas del Director','project_information',false]
 ];
 for(const [text,type,execute] of cases){const got=await classify(text);assert.equal(got.type,type,text);assert.equal(got.execute,execute,text)}

 const unsafe=await fetch(`${base}/api/director/command`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({command:'¿Qué está haciendo el Director?'})});
 assert.equal(unsafe.status,400);
 assert.equal((await unsafe.json()).error,'explicit_cycle_command_required');

 const switchSol=await fetch(`${base}/api/jarvis`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({text:'Hablar con Sol',messages:[]})});
 assert.equal(switchSol.status,200);
 const switchBody=await switchSol.json();
 assert.equal(switchBody.type,'switch');
 assert.equal(switchBody.active.mode,'sol');
 assert.equal(switchBody.active.projectName,'Director / ContentFlow');
});
