import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const workflow = readFileSync('.github/workflows/nebius-gpu-contentflow.yml','utf8');
const preflight = readFileSync('ops/nebius/contentflow-gpu-preflight.sh','utf8');

test('host is dynamic and private key is secret-backed', () => {
  assert.match(workflow, /vars\.NEBIUS_HOST/);
  assert.match(workflow, /inputs\.nebius_host/);
  assert.match(workflow, /HOST_DISCOVERY_REQUIRED/);
  assert.match(workflow, /secrets\.NEBIUS_SSH_PRIVATE_KEY/);
  assert.doesNotMatch(workflow, /195\.242\.10\.(54|122)/);
  assert.doesNotMatch(preflight, /195\.242\.10\.(54|122)/);
});

test('SSH readiness is retryable and key is validated before use', () => {
  assert.match(preflight, /SSH_READY_ATTEMPTS:=36/);
  assert.match(preflight, /ssh-keyscan/);
  assert.match(preflight, /ssh-keygen -y/);
  assert.match(preflight, /RETRYABLE_INFRA/);
  assert.match(preflight, /ConnectTimeout=10/);
  assert.match(preflight, /ServerAliveInterval=15/);
  assert.match(preflight, /ServerAliveCountMax=3/);
});

test('GPU_READY requires host GPU, Docker, toolkit and Docker GPU', () => {
  assert.match(preflight, /nvidia-smi --query-gpu=name,memory\.total,driver_version/);
  assert.match(preflight, /sudo docker --version/);
  assert.match(preflight, /nvidia-ctk --version/);
  assert.match(preflight, /docker run --rm --gpus all nvidia\/cuda:12\.4\.1-base-ubuntu22\.04 nvidia-smi/);
  assert.match(preflight, /GPU_RUNTIME_FAULT/);
  assert.match(preflight, /NVIDIA_CONTAINER_RUNTIME_FAULT/);
  assert.match(preflight, /NEBIUS_GPU_STATE=GPU_READY/);
});

test('deployment is isolated, atomic and run-scoped', () => {
  assert.match(workflow, /~\/workspaces\/contentflow\/\{data,evidence,logs,models,cache,runs,runtime\}/);
  assert.match(workflow, /release\.next/);
  assert.match(workflow, /release\.current/);
  assert.match(workflow, /release\.previous/);
  assert.match(workflow, /github\.run_id/);
  assert.match(workflow, /workspaces\/contentflow\/runs\/\$RUN_ID/);
  assert.doesNotMatch(workflow, /workspaces\/avatar/);
  assert.doesNotMatch(workflow, /\/tmp\/run\.sh|\/tmp\/result\.json/);
});

test('evidence is uploaded and never includes credential material by design', () => {
  assert.match(workflow, /Upload Nebius GPU evidence/);
  assert.match(preflight, /gpu_model/);
  assert.match(preflight, /gpu_memory/);
  assert.match(preflight, /driver/);
  assert.match(preflight, /docker_gpu/);
  assert.doesNotMatch(preflight, /private_key.*JSON|password.*JSON|token.*JSON/i);
});
