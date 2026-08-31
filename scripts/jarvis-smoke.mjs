import { spawn } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import process from 'node:process';

const PORT = 44317;
const BASE = `http://127.0.0.1:${PORT}`;
const EXPECTED_BUILD = '2026-08-31-conversation-router-v5.3';
const server = spawn(process.execPath, ['src/jarvis/server.mjs'], {
  env: { ...process.env, JARVIS_PORT: String(PORT), JARVIS_HOST: '127.0.0.1' },
  stdio: ['ignore', 'pipe', 'pipe']
});

let stderr = '';
server.stderr.on('data', d => stderr += d.toString());

const sleep = ms => new Promise(r => setTimeout(r, ms));
async function waitForHealth() {
  for (let i = 0; i < 40; i++) {
    try {
      const r = await fetch(`${BASE}/health`, { cache: 'no-store' });
      if (r.ok) return r.json();
    } catch {}
    await sleep(100);
  }
  throw new Error(`Jarvis no inició en smoke test. ${stderr}`);
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

try {
  const health = await waitForHealth();
  assert(health.ok === true, 'health.ok no es true');
  assert(health.build === EXPECTED_BUILD, `build inesperado: ${health.build}`);
  assert(health.openaiModel === 'gpt-5.6-sol', `modelo inesperado: ${health.openaiModel}`);
  assert(Array.isArray(health.availableProjects) && health.availableProjects.length === 3, 'deben existir 3 proyectos operativos');

  const self = await (await fetch(`${BASE}/api/selftest`, { cache: 'no-store' })).json();
  assert(self.ok === true, 'router self-test falló');
  assert(self.passed === self.total && self.total >= 20, `router incompleto ${self.passed}/${self.total}`);

  const classify = async text => {
    const r = await fetch(`${BASE}/api/classify`, { method:'POST', headers:{'content-type':'application/json'}, body:JSON.stringify({text}) });
    assert(r.ok, `classify HTTP ${r.status} para ${text}`);
    return r.json();
  };
  const negatives = ['¿Qué está haciendo el Director?','revisa el Director','trabaja con Director','¿cómo va Avatar?','qué tareas tiene Skool'];
  for (const text of negatives) {
    const r = await classify(text);
    assert(r.execute === false, `falso positivo de ejecución: ${text}`);
  }
  for (const [text,project] of [['ejecuta un ciclo del Director','contentflow'],['corre el run de Avatar','avatar'],['lanza un ciclo de Skool','academy']]) {
    const r = await classify(text);
    assert(r.type === 'project_cycle' && r.execute === true && r.project === project, `orden explícita mal clasificada: ${text}`);
  }

  const ui = await readFile('src/jarvis/ui.html','utf8');
  assert(ui.includes("location.protocol==='file:'"), 'UI no protege apertura file://');
  assert(ui.includes('SpeechRecognition') || ui.includes('webkitSpeechRecognition'), 'UI sin reconocimiento de voz');
  assert(ui.includes('speechSynthesis'), 'UI sin síntesis de voz');
  assert(ui.includes('Interlocutor'), 'UI sin indicador de interlocutor');
  assert(ui.includes('/api/selftest'), 'UI sin indicador de self-test del router');

  const launcher = await readFile('JARVIS-WINDOWS.cmd','utf8');
  assert(launcher.includes('node "src\\jarvis\\server.mjs"'), 'launcher no inicia el servidor correcto');
  assert(!launcher.includes('start "" "http://127.0.0.1:4317"'), 'launcher abre el navegador antes del servidor');

  console.log(JSON.stringify({ok:true,build:health.build,router:`${self.passed}/${self.total}`,voiceContract:true,windowsLauncherContract:true,projects:health.availableProjects.map(p=>p.id)},null,2));
} finally {
  server.kill('SIGTERM');
}
