const BASE=process.env.JARVIS_BASE_URL||'http://127.0.0.1:4317';
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
async function post(path,body){const r=await fetch(BASE+path,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)});const b=await r.json();if(!r.ok)throw new Error(`${path} ${r.status}: ${JSON.stringify(b)}`);return b}
const health=await fetch(BASE+'/health').then(r=>r.json());
if(!health?.ok)throw new Error('health failed');
let failed=0;
for(const [text,type,execute] of cases){const got=await post('/api/classify',{text});const ok=got.type===type&&got.execute===execute;console.log(`${ok?'PASS':'FAIL'} | ${text} -> ${got.type} execute=${got.execute}`);if(!ok)failed++}
const unsafe=await fetch(BASE+'/api/director/command',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({command:'¿Qué está haciendo el Director?'})});
if(unsafe.status!==400){console.error(`FAIL | direct endpoint accepted non-explicit command: ${unsafe.status}`);failed++}else console.log('PASS | direct endpoint rejects non-explicit command');
if(failed){console.error(`Jarvis smoke test FAILED: ${failed} case(s)`);process.exit(1)}
console.log(`Jarvis smoke test PASS | build=${health.build} | ${cases.length+1} checks`);
