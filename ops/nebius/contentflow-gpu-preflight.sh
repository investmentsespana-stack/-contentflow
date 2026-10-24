#!/usr/bin/env bash
set -euo pipefail

: "${NEBIUS_HOST:?NEBIUS_HOST required}"
: "${NEBIUS_USER:=ubuntu}"
: "${NEBIUS_KEY_PATH:?NEBIUS_KEY_PATH required}"
: "${EVIDENCE_PATH:=certification-evidence/nebius-gpu-preflight.json}"
: "${SSH_READY_ATTEMPTS:=36}"
: "${SSH_READY_SLEEP_SECONDS:=10}"

SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=3
)

mkdir -p "$(dirname "$EVIDENCE_PATH")" ~/.ssh
chmod 700 ~/.ssh
: > ~/.ssh/known_hosts
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

write_failure() {
  local class="$1" reason="$2"
  node - "$EVIDENCE_PATH" "$NEBIUS_HOST" "$started_at" "$class" "$reason" <<'NODE'
const fs = require('node:fs');
const [path, host, startedAt, errorClass, reason] = process.argv.slice(2);
fs.writeFileSync(path, JSON.stringify({
  architecture: 'NEBIUS_GPU_CONNECTION_V1',
  host,
  ssh: 'FAIL',
  gpu_visible: false,
  docker: 'UNKNOWN',
  nvidia_container_toolkit: 'UNKNOWN',
  docker_gpu: 'UNKNOWN',
  workload: 'NOT_RUN',
  error_class: errorClass,
  reason,
  host_revalidation_required: errorClass === 'RETRYABLE_INFRA',
  started_at: startedAt,
  finished_at: new Date().toISOString(),
}, null, 2) + '\n');
NODE
  echo "NEBIUS_ERROR_CLASS=$class"
  echo "NEBIUS_ERROR_REASON=$reason"
  exit 1
}

if ! ssh-keygen -y -f "$NEBIUS_KEY_PATH" >/dev/null 2>&1; then
  write_failure SSH_KEY_INVALID private_key_unreadable
fi

ready=0
for attempt in $(seq 1 "$SSH_READY_ATTEMPTS"); do
  echo "[ssh] readiness attempt $attempt/$SSH_READY_ATTEMPTS"
  if keyscan="$(timeout 12s ssh-keyscan -T 8 -H "$NEBIUS_HOST" 2>/dev/null)" && [[ -n "$keyscan" ]]; then
    printf '%s\n' "$keyscan" > ~/.ssh/known_hosts
    if ssh "${SSH_OPTS[@]}" -i "$NEBIUS_KEY_PATH" "$NEBIUS_USER@$NEBIUS_HOST" 'echo SSH_READY' 2>/dev/null | grep -q SSH_READY; then
      ready=1
      break
    fi
  fi
  sleep "$SSH_READY_SLEEP_SECONDS"
done

if [[ "$ready" != 1 ]]; then
  write_failure RETRYABLE_INFRA ssh_not_ready_after_retry_window
fi

remote_out="$(ssh "${SSH_OPTS[@]}" -i "$NEBIUS_KEY_PATH" "$NEBIUS_USER@$NEBIUS_HOST" 'bash -se' <<'REMOTE'
set -euo pipefail
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo 'ERROR_CLASS=GPU_RUNTIME_FAULT'
  echo 'ERROR_REASON=nvidia_smi_missing'
  exit 41
fi
if ! gpu_line="$(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader | head -n1)" || [[ -z "$gpu_line" ]]; then
  echo 'ERROR_CLASS=GPU_RUNTIME_FAULT'
  echo 'ERROR_REASON=nvidia_smi_query_failed'
  exit 42
fi
if ! docker_version="$(sudo docker --version 2>/dev/null)"; then
  echo 'ERROR_CLASS=NVIDIA_CONTAINER_RUNTIME_FAULT'
  echo 'ERROR_REASON=docker_unavailable'
  exit 43
fi
if ! nvidia_ctk_version="$(nvidia-ctk --version 2>/dev/null | head -n1)"; then
  echo 'ERROR_CLASS=NVIDIA_CONTAINER_RUNTIME_FAULT'
  echo 'ERROR_REASON=nvidia_ctk_unavailable'
  exit 44
fi
if ! sudo docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi >/tmp/contentflow-docker-gpu-check.txt 2>&1; then
  echo 'ERROR_CLASS=NVIDIA_CONTAINER_RUNTIME_FAULT'
  echo 'ERROR_REASON=docker_gpu_check_failed'
  exit 45
fi
printf 'SSH_OK=1\n'
printf 'GPU_LINE=%s\n' "$gpu_line"
printf 'DOCKER_VERSION=%s\n' "$docker_version"
printf 'NVIDIA_CTK_VERSION=%s\n' "$nvidia_ctk_version"
printf 'DOCKER_GPU_OK=1\n'
REMOTE
)" || {
  class="$(printf '%s\n' "$remote_out" | sed -n 's/^ERROR_CLASS=//p' | tail -n1)"
  reason="$(printf '%s\n' "$remote_out" | sed -n 's/^ERROR_REASON=//p' | tail -n1)"
  write_failure "${class:-GPU_RUNTIME_FAULT}" "${reason:-remote_preflight_failed}"
}

gpu_line="$(printf '%s\n' "$remote_out" | sed -n 's/^GPU_LINE=//p' | tail -n1)"
docker_version="$(printf '%s\n' "$remote_out" | sed -n 's/^DOCKER_VERSION=//p' | tail -n1)"
nvidia_ctk_version="$(printf '%s\n' "$remote_out" | sed -n 's/^NVIDIA_CTK_VERSION=//p' | tail -n1)"

gpu_model="${gpu_line%%,*}"
rest="${gpu_line#*, }"
gpu_memory="${rest%%,*}"
driver="${gpu_line##*, }"

node - "$EVIDENCE_PATH" "$NEBIUS_HOST" "$gpu_model" "$gpu_memory" "$driver" "$docker_version" "$nvidia_ctk_version" "$started_at" <<'NODE'
const fs = require('node:fs');
const [path, host, gpuModel, gpuMemory, driver, dockerVersion, ctkVersion, startedAt] = process.argv.slice(2);
fs.writeFileSync(path, JSON.stringify({
  architecture: 'NEBIUS_GPU_CONNECTION_V1',
  host,
  ssh: 'PASS',
  gpu_visible: true,
  gpu_model: gpuModel.trim(),
  gpu_memory: gpuMemory.trim(),
  driver: driver.trim(),
  docker: 'PASS',
  docker_version: dockerVersion.trim(),
  nvidia_container_toolkit: 'PASS',
  nvidia_container_toolkit_version: ctkVersion.trim(),
  docker_gpu: 'PASS',
  workload: 'NOT_RUN',
  error_class: null,
  started_at: startedAt,
  finished_at: null,
}, null, 2) + '\n');
NODE

echo 'NEBIUS_GPU_STATE=GPU_READY'
