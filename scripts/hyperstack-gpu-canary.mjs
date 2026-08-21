import { execFileSync } from 'node:child_process';
import fs from 'node:fs';

const BASE = 'https://infrahub-api.nexgencloud.com/v1';
const apiKey = process.env.HYPERSTACK_API_KEY;
const vmName = process.env.HYPERSTACK_VM_NAME || 'ambitious-schrodinger';
const mode = process.env.HYPERSTACK_MODE || 'inspect';
const sshKeyPath = process.env.HYPERSTACK_SSH_KEY_PATH || '';
const maxRuntimeMinutes = Math.min(Number(process.env.HYPERSTACK_MAX_RUNTIME_MINUTES || '10'), 15);
const evidencePath = process.env.HYPERSTACK_EVIDENCE_PATH || 'certification-evidence/hyperstack-gpu-canary.json';

if (!apiKey) throw new Error('HYPERSTACK_API_KEY is required');
if (!['inspect', 'canary'].includes(mode)) throw new Error('HYPERSTACK_MODE must be inspect or canary');
if (!Number.isFinite(maxRuntimeMinutes) || maxRuntimeMinutes <= 0) throw new Error('invalid runtime budget');

const headers = { api_key: apiKey, accept: 'application/json' };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const startedAt = new Date();
const evidence = {
  schema: 'hyperstack-gpu-canary.v1',
  started_at: startedAt.toISOString(),
  vm_name: vmName,
  mode,
  max_runtime_minutes: maxRuntimeMinutes,
  actions: [],
  runtime_verified: false,
  final_hibernated: false,
};

function record(action, detail = {}) {
  evidence.actions.push({ at: new Date().toISOString(), action, ...detail });
}

async function request(path) {
  const response = await fetch(`${BASE}${path}`, { headers });
  const text = await response.text();
  let body;
  try { body = JSON.parse(text); } catch { body = { raw: text.slice(0, 1000) }; }
  if (!response.ok) throw new Error(`Hyperstack ${response.status}: ${JSON.stringify(body)}`);
  return body;
}

function flattenCandidates(body) {
  const candidates = [];
  if (Array.isArray(body)) candidates.push(...body);
  for (const key of ['instances', 'virtual_machines', 'data', 'results']) {
    if (Array.isArray(body?.[key])) candidates.push(...body[key]);
  }
  if (body?.instance && typeof body.instance === 'object') candidates.push(body.instance);
  return candidates;
}

async function findVm() {
  const body = await request(`/core/virtual-machines?search=${encodeURIComponent(vmName)}&pageSize=50`);
  const vm = flattenCandidates(body).find((x) => x?.name === vmName);
  if (!vm) throw new Error(`allowlisted VM not found: ${vmName}`);
  if (!Number.isInteger(Number(vm.id))) throw new Error('VM id missing');
  return vm;
}

async function getVm(id) {
  const body = await request(`/core/virtual-machines/${id}`);
  return body.instance || body;
}

async function action(id, name) {
  if (!['hibernate', 'hibernate-restore', 'start'].includes(name)) throw new Error(`action not allowlisted: ${name}`);
  record('api_action_requested', { name });
  return request(`/core/virtual-machines/${id}/${name}`);
}

async function waitFor(id, expected, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let last;
  while (Date.now() < deadline) {
    const vm = await getVm(id);
    last = String(vm.status || '').toUpperCase();
    record('state_observed', { status: last });
    if (last === expected) return vm;
    await sleep(10000);
  }
  throw new Error(`timeout waiting for ${expected}; last=${last}`);
}

function runGpuProbe(ip) {
  if (!sshKeyPath || !fs.existsSync(sshKeyPath)) throw new Error('fresh SSH key file is required for canary mode');
  const args = [
    '-i', sshKeyPath,
    '-o', 'BatchMode=yes',
    '-o', 'StrictHostKeyChecking=accept-new',
    '-o', 'ConnectTimeout=15',
    `ubuntu@${ip}`,
    'nvidia-smi --query-gpu=name,memory.total,memory.used,utilization.gpu,temperature.gpu --format=csv,noheader,nounits'
  ];
  const output = execFileSync('ssh', args, { encoding: 'utf8', timeout: 60000 }).trim();
  record('gpu_probe', { output });
  return output;
}

async function ensureHibernated(id) {
  try {
    const vm = await getVm(id);
    const status = String(vm.status || '').toUpperCase();
    if (status !== 'HIBERNATED' && status !== 'HIBERNATING') await action(id, 'hibernate');
    await waitFor(id, 'HIBERNATED', 20 * 60 * 1000);
    evidence.final_hibernated = true;
  } catch (error) {
    evidence.hibernate_error = String(error?.message || error);
    throw error;
  }
}

let vmId;
let primaryError;
try {
  const vm = await findVm();
  vmId = Number(vm.id);
  evidence.vm_id = vmId;
  evidence.initial_status = String(vm.status || '').toUpperCase();
  evidence.initial_ip = vm.floating_ip || vm.public_ip || null;
  record('vm_discovered', { id: vmId, status: evidence.initial_status });

  if (mode === 'inspect') {
    evidence.success = true;
  } else {
    let current = await getVm(vmId);
    let status = String(current.status || '').toUpperCase();
    if (status === 'HIBERNATED') await action(vmId, 'hibernate-restore');
    else if (status === 'SHUTOFF') await action(vmId, 'start');
    else if (status !== 'ACTIVE') throw new Error(`unsafe initial state for canary: ${status}`);

    current = await waitFor(vmId, 'ACTIVE', 20 * 60 * 1000);
    const ip = current.floating_ip || current.public_ip;
    if (!ip) throw new Error('ACTIVE VM has no public IP');
    evidence.active_ip = ip;
    runGpuProbe(ip);
    evidence.runtime_verified = true;
    evidence.success = true;
  }
} catch (error) {
  primaryError = error;
  evidence.success = false;
  evidence.error = String(error?.message || error);
} finally {
  if (mode === 'canary' && vmId) {
    try { await ensureHibernated(vmId); }
    catch (hibernateError) {
      evidence.success = false;
      if (!primaryError) primaryError = hibernateError;
    }
  }
  evidence.finished_at = new Date().toISOString();
  evidence.elapsed_seconds = Math.round((Date.now() - startedAt.getTime()) / 1000);
  fs.mkdirSync(new URL('../certification-evidence/', import.meta.url), { recursive: true });
  fs.writeFileSync(evidencePath, `${JSON.stringify(evidence, null, 2)}\n`);
}

if (primaryError) throw primaryError;
console.log(JSON.stringify({ success: evidence.success, runtime_verified: evidence.runtime_verified, final_hibernated: evidence.final_hibernated, evidence: evidencePath }));
