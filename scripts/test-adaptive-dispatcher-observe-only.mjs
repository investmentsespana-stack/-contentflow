import fs from 'node:fs';
const p='supabase/functions/contentflow-adaptive-dispatcher/index.ts';
const s=fs.readFileSync(p,'utf8');
const forbidden=[".update(",".insert(",".upsert(",".delete(","contentflow-dispatch-executor-v2","EdgeRuntime.waitUntil"];
for(const token of forbidden){if(s.includes(token)) throw new Error(`adaptive dispatcher must be observe-only; forbidden token: ${token}`)}
for(const required of ["mode:'observe_only'","accepted:0","mutations:0","single_writer:'director_core'"]){if(!s.includes(required)) throw new Error(`missing observe-only receipt: ${required}`)}
console.log('adaptive dispatcher observe-only single-writer contract: PASS');
