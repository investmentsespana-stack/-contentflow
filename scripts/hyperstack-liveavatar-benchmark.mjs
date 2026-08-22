import { execFileSync } from 'node:child_process';
import fs from 'node:fs';

const BASE = 'https://infrahub-api.nexgencloud.com/v1';
const apiKey = process.env.HYPERSTACK_API_KEY;
const vmName = process.env.HYPERSTACK_VM_NAME || 'ambitious-schrodinger';
const sshKeyPath = process.env.HYPERSTACK_SSH_KEY_PATH || '';
const evidencePath = process.env.HYPERSTACK_EVIDENCE_PATH || 'certification-evidence/liveavatar-a100-benchmark.json';
const maxRuntimeMinutes = Math.min(Number(process.env.HYPERSTACK_MAX_RUNTIME_MINUTES || '80'), 90);

if (!apiKey) throw new Error('HYPERSTACK_API_KEY is required');
if (!sshKeyPath || !fs.existsSync(sshKeyPath)) throw new Error('HYPERSTACK_SSH_KEY_PATH is required');

const headers = { api_key: apiKey, accept: 'application/json' };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const startedAt = new Date();
const evidence = {
  schema: 'liveavatar-a100-benchmark.v1',
  started_at: startedAt.toISOString(),
  vm_name: vmName,
  max_runtime_minutes: maxRuntimeMinutes,
  actions: [],
  gpu_verified: false,
  liveavatar_repo_ready: false,
  dependencies_ready: false,
  models_ready: false,
  inference_completed: false,
  final_hibernated: false,
  success: false,
};

function record(action, detail = {}) {
  evidence.actions.push({ at: new Date().toISOString(), action, ...detail });
}

async function request(path) {
  const response = await fetch(`${BASE}${path}`, { headers });
  const text = await response.text();
  let body;
  try { body = JSON.parse(text); } catch { body = { raw: text.slice(0, 1200) }; }
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

function ssh(ip, command, timeoutMs) {
  const args = [
    '-i', sshKeyPath,
    '-o', 'BatchMode=yes',
    '-o', 'StrictHostKeyChecking=accept-new',
    '-o', 'ConnectTimeout=20',
    '-o', 'ServerAliveInterval=30',
    '-o', 'ServerAliveCountMax=6',
    `ubuntu@${ip}`,
    'bash', '-lc', command,
  ];
  return execFileSync('ssh', args, { encoding: 'utf8', timeout: timeoutMs, maxBuffer: 16 * 1024 * 1024 }).trim();
}

async function waitSsh(ip, timeoutMs = 8 * 60 * 1000) {
  const deadline = Date.now() + timeoutMs;
  let last = '';
  while (Date.now() < deadline) {
    try {
      const out = ssh(ip, 'echo SSH_OK', 30000);
      if (out.includes('SSH_OK')) return;
    } catch (e) { last = String(e?.message || e).slice(0, 300); }
    await sleep(10000);
  }
  throw new Error(`SSH not ready: ${last}`);
}

async function ensureHibernated(id) {
  const vm = await getVm(id);
  const status = String(vm.status || '').toUpperCase();
  if (status !== 'HIBERNATED' && status !== 'HIBERNATING') await action(id, 'hibernate');
  await waitFor(id, 'HIBERNATED', 20 * 60 * 1000);
  evidence.final_hibernated = true;
}

const remoteScript = String.raw`
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
WORK="$HOME/liveavatar-bench"
mkdir -p "$WORK"
cd "$WORK"

echo '=== GPU ==='
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader

echo '=== SYSTEM PACKAGES ==='
sudo apt-get update -y >/tmp/liveavatar-apt-update.log 2>&1
sudo apt-get install -y git ffmpeg python3-venv python3-dev build-essential ninja-build >/tmp/liveavatar-apt-install.log 2>&1

if [ ! -d LiveAvatar/.git ]; then
  git clone --depth 1 https://github.com/Alibaba-Quark/LiveAvatar.git LiveAvatar
else
  git -C LiveAvatar fetch --depth 1 origin main
  git -C LiveAvatar reset --hard origin/main
fi
cd LiveAvatar
printf 'LIVEAVATAR_COMMIT=%s\n' "$(git rev-parse HEAD)"

if [ ! -d .venv ]; then python3 -m venv .venv; fi
source .venv/bin/activate
python -m pip install -U pip setuptools wheel

# A100/Ampere path. Use CUDA 12.4-compatible PyTorch wheels to stay within the VM driver envelope.
python -m pip install --extra-index-url https://download.pytorch.org/whl/cu124 'torch>=2.4,<2.7' 'torchvision>=0.19,<0.22' torchaudio
python -m pip install -r requirements.txt
python -m pip install 'flash-attn>=2.7,<2.9' --no-build-isolation

echo '=== PYTORCH GPU CHECK ==='
python - <<'PY'
import torch
print('torch', torch.__version__)
print('cuda_available', torch.cuda.is_available())
print('cuda_runtime', torch.version.cuda)
print('gpu', torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'NONE')
if not torch.cuda.is_available():
    raise SystemExit(2)
PY

mkdir -p ckpt
python -m pip install -U 'huggingface_hub[cli]'
if [ ! -f ckpt/Wan2.2-S2V-14B/config.json ]; then
  huggingface-cli download Wan-AI/Wan2.2-S2V-14B --local-dir ./ckpt/Wan2.2-S2V-14B
fi
if [ ! -d ckpt/LiveAvatar ]; then
  huggingface-cli download Quark-Vision/Live-Avatar --local-dir ./ckpt/LiveAvatar
fi

echo '=== MODEL CHECK ==='
test -f ckpt/Wan2.2-S2V-14B/config.json
find ckpt/LiveAvatar -maxdepth 2 -type f | head -20

export ENABLE_COMPILE=false
export NCCL_DEBUG=WARN
export NCCL_DEBUG_SUBSYS=OFF
START=$(date +%s)
set +e
CUDA_VISIBLE_DEVICES=0 torchrun --nproc_per_node=1 --master_port=29101 minimal_inference/s2v_streaming_interact.py \
  --ulysses_size 1 \
  --task s2v-14B \
  --size '704*384' \
  --base_seed 420 \
  --training_config liveavatar/configs/s2v_causal_sft.yaml \
  --offload_model True \
  --convert_model_dtype \
  --prompt 'A friendly presenter speaking naturally to camera in a professional studio.' \
  --image examples/dwarven_blacksmith.jpg \
  --audio examples/dwarven_blacksmith.wav \
  --infer_frames 48 \
  --load_lora \
  --lora_path_dmd Quark-Vision/Live-Avatar \
  --sample_steps 4 \
  --sample_guide_scale 0 \
  --num_clip 1 \
  --num_gpus_dit 1 \
  --sample_solver euler \
  --single_gpu \
  --ckpt_dir ckpt/Wan2.2-S2V-14B/ \
  --fp8 2>&1 | tee "$WORK/liveavatar-inference.log"
RC=${PIPESTATUS[0]}
set -e
END=$(date +%s)
printf 'INFERENCE_EXIT=%s\n' "$RC"
printf 'INFERENCE_SECONDS=%s\n' "$((END-START))"
printf 'GPU_POST=%s\n' "$(nvidia-smi --query-gpu=memory.used,utilization.gpu,temperature.gpu --format=csv,noheader,nounits | head -1)"
find . -maxdepth 4 -type f \( -name '*.mp4' -o -name '*.gif' -o -name '*.webm' \) -printf 'OUTPUT=%p %s bytes\n' | tail -20
exit "$RC"
`;

let vmId;
let primaryError;
try {
  const vm = await findVm();
  vmId = Number(vm.id);
  evidence.vm_id = vmId;
  evidence.initial_status = String(vm.status || '').toUpperCase();
  record('vm_discovered', { id: vmId, status: evidence.initial_status });

  let current = await getVm(vmId);
  let status = String(current.status || '').toUpperCase();
  if (status === 'HIBERNATED') await action(vmId, 'hibernate-restore');
  else if (status === 'SHUTOFF') await action(vmId, 'start');
  else if (status !== 'ACTIVE') throw new Error(`unsafe initial state: ${status}`);

  current = await waitFor(vmId, 'ACTIVE', 20 * 60 * 1000);
  const ip = current.floating_ip || current.public_ip;
  if (!ip) throw new Error('ACTIVE VM has no public IP; attach public IP before benchmark');
  evidence.active_ip = ip;
  await waitSsh(ip);
  record('ssh_ready');

  const probe = ssh(ip, 'nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits', 60000);
  evidence.gpu_probe = probe;
  evidence.gpu_verified = /A100/i.test(probe) && /81920|80/i.test(probe);
  if (!evidence.gpu_verified) throw new Error(`unexpected GPU probe: ${probe}`);

  const encoded = Buffer.from(remoteScript, 'utf8').toString('base64');
  record('liveavatar_benchmark_started');
  const output = ssh(ip, `echo ${encoded} | base64 -d | bash`, maxRuntimeMinutes * 60 * 1000);
  evidence.remote_tail = output.split('\n').slice(-120);
  evidence.liveavatar_repo_ready = output.includes('LIVEAVATAR_COMMIT=');
  evidence.dependencies_ready = output.includes('=== PYTORCH GPU CHECK ===') && output.includes('cuda_available True');
  evidence.models_ready = output.includes('=== MODEL CHECK ===');
  evidence.inference_completed = output.includes('INFERENCE_EXIT=0');
  evidence.inference_seconds = Number((output.match(/INFERENCE_SECONDS=(\d+)/) || [])[1] || 0) || null;
  evidence.outputs = output.split('\n').filter((x) => x.startsWith('OUTPUT=')).slice(-20);
  evidence.success = evidence.gpu_verified && evidence.liveavatar_repo_ready && evidence.dependencies_ready && evidence.models_ready && evidence.inference_completed;
  if (!evidence.success) throw new Error('LiveAvatar benchmark did not reach successful inference');
} catch (error) {
  primaryError = error;
  evidence.error = String(error?.message || error);
  evidence.success = false;
} finally {
  if (vmId) {
    try { await ensureHibernated(vmId); }
    catch (e) { evidence.hibernate_error = String(e?.message || e); evidence.success = false; if (!primaryError) primaryError = e; }
  }
  evidence.finished_at = new Date().toISOString();
  evidence.elapsed_seconds = Math.round((Date.now() - startedAt.getTime()) / 1000);
  fs.mkdirSync(new URL('../certification-evidence/', import.meta.url), { recursive: true });
  fs.writeFileSync(evidencePath, `${JSON.stringify(evidence, null, 2)}\n`);
}

if (primaryError) throw primaryError;
console.log(JSON.stringify({ success: evidence.success, inference_completed: evidence.inference_completed, inference_seconds: evidence.inference_seconds, final_hibernated: evidence.final_hibernated, evidence: evidencePath }));
