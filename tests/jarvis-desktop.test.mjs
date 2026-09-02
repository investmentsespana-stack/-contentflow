import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { buildAvatarProjectState } from '../src/jarvis/avatar-project-state.mjs';

const port=44317;
const base=`http://127.0.0.1:${port}`;
async function waitForHealth(){for(let i=0;i<50;i++){try{const r=await fetch(`${base}/health`);if(r.ok)return r}catch{}await new Promise(r=>setTimeout(r,100))}throw new Error('server did not start')}
async function classify(text){const r=await fetch(`${base}/api/classify`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({text})});assert.equal(r.status,200);return r.json()}

test('Avatar project state reconciler detects hub/GitHub conflicts fail-closed',async()=>{
 const mockFetch=async url=>{
  const payload=String(url).includes('/actions/runs')?{workflow_runs:[
   {id:10,name:'Validate',run_number:10,status:'completed',conclusion:'success',head_sha:'abc',updated_at:'2026-09-02T02:00:00Z',html_url:'https://github.test/run/10'},
   {id:11,name:'Avatar Parallel Non-GPU Lanes',run_number:11,status:'in_progress',conclusion:null,head_sha:'abc',updated_at:'2026-09-02T02:01:00Z',html_url:'https://github.test/run/11'},
   {id:12,name:'Director RARA Autonomy Watchdog',run_number:12,status:'completed',conclusion:'success',head_sha:'abc',updated_at:'2026-09-02T02:02:00Z',html_url:'https://github.test/run/12'}
  ]}:{items:[{number:5,title:'watchdog','state':'open',updated_at:'2026-09-02T02:02:00Z',html_url:'https://github.test/issues/5'}]};
  return {ok:true,status:200,text:async()=>JSON.stringify(payload)};
 };
 const state=await buildAvatarProjectState({hubState:{active_tasks:0},fetchImpl:mockFetch,now:new Date('2026-09-02T02:03:00Z')});
 assert.equal(state.state,'CONFLICT_DETECTED');
 assert.equal(state.canonical,false);
 assert.equal(state.sources.github.ok,true);
 assert.equal(state.director_watchdog_issues.length,1);
 assert.equal(state.workflows['Validate'].conclusion,'success');
 assert.equal(state.workflows['Avatar Parallel Non-GPU Lanes'].status,'in_progress');
 assert.equal(state.conflicts[0].type,'HUB_GITHUB_ACTIVITY_CONFLICT');
});

test('Avatar project state reconciler never fabricates canonical state when hub is absent',async()=>{
 const mockFetch=async url=>({ok:true,status:200,text:async()=>JSON.stringify(String(url).includes('/actions/runs')?{workflow_runs:[]}:{items:[]})});
 const state=await buildAvatarProjectState({fetchImpl:mockFetch,now:new Date('2026-09-02T02:03:00Z')});
 assert.equal(state.state,'GITHUB_LIVE_HUB_UNAVAILABLE');
 assert.equal(state.canonical,false);
 assert.equal(state.sources.hub.ok,false);
});

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
 assert.equal(body.build,'2026-09-02-avatar-live-reconciler-v5.4');
 assert.equal(body.openaiModel,'gpt-5.6-sol');
 assert.equal(body.availableProjects.length,3);

 const cases=[
  ['¿Qué está haciendo el Director?','project_information',false],
  ['Dame reporte del Director','project_information',false],
  ['¿Cómo va Avatar?','project_information',false],
  ['Reporte de Skool','project_information',false],
  ['Hablar con Sol','switch_sol',false],
  ['Comunícame con ChatGPT','switch_sol',false],
  ['Pásame con el Director','switch_project',false],
  ['Entra a Avatar','switch_project',false],
  ['Hablar con Skool','switch_project',false],
  ['Vuelve a Jarvis','switch_jarvis',false],
  ['Ejecuta un ciclo del Director','project_cycle',true],
  ['Corre un run de Avatar','project_cycle',true],
  ['Arranca un ciclo de Skool','project_cycle',true],
  ['Revisa el Director','chat',false],
  ['Continúa con Avatar','chat',false],
  ['Ejecuta tareas del Director','project_information',false]
 ];
 for(const [text,type,execute] of cases){const got=await classify(text);assert.equal(got.type,type,text);assert.equal(got.execute,execute,text)}

 const self=await fetch(`${base}/api/selftest`);
 assert.equal(self.status,200);
 const selfBody=await self.json();
 assert.equal(selfBody.ok,true);
 assert.equal(selfBody.passed,selfBody.total);
 assert.ok(selfBody.total>=20);

 const unsafe=await fetch(`${base}/api/director/command`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({command:'¿Qué está haciendo el Director?'})});
 assert.equal(unsafe.status,400);
 assert.equal((await unsafe.json()).error,'explicit_cycle_command_required');

 const switchSol=await fetch(`${base}/api/jarvis`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({text:'Hablar con Sol',messages:[]})});
 assert.equal(switchSol.status,200);
 const switchBody=await switchSol.json();
 assert.equal(switchBody.type,'switch');
 assert.equal(switchBody.active.mode,'sol');
 assert.equal(switchBody.active.projectName,'Director / ContentFlow');

 const back=await fetch(`${base}/api/jarvis`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({text:'Vuelve a Jarvis',messages:[]})});
 assert.equal(back.status,200);
 const backBody=await back.json();
 assert.equal(backBody.type,'switch');
 assert.equal(backBody.active.mode,'jarvis');
});
