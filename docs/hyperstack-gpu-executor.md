# Hyperstack GPU Executor — isolated integration

Status: DESIGN / NOT MERGED
Branch: `feature/hyperstack-gpu-executor`

## Purpose
Give the Director/Orchestrator a controlled infrastructure lane for GPU benchmarks without requiring the owner to operate SSH/Linux manually.

Initial workload: LiveAvatar + Qwen benchmark on a Hyperstack A100 80 GB VM.

## Safety boundary
- This branch MUST remain isolated from `main` until reviewed and explicitly approved.
- Never store Hyperstack API keys, SSH private keys, passwords, or other secrets in GitHub or chat transcripts.
- The previously exposed SSH private key must not be reused by the executor; provision a fresh dedicated credential before activation.
- Default state is GPU OFF/HIBERNATED.
- No autonomous purchasing, credit top-ups, VM creation, deletion, resizing, or cluster creation.
- Only an explicitly allowlisted existing VM may be controlled.
- Every infrastructure action must be logged with project, task, actor, timestamp, VM, action, result, duration, GPU metrics, and estimated cost.

## Required capabilities
1. Read VM state and GPU metadata.
2. Restore/start the allowlisted VM only for an approved benchmark run.
3. Wait for ACTIVE + SSH health.
4. Execute an allowlisted benchmark job through a dedicated non-owner credential.
5. Capture stdout/stderr, exit code, timings, GPU utilization/VRAM, FPS/latency and artifacts.
6. Enforce a hard runtime/cost budget.
7. Hibernate the VM on success, failure, timeout, cancellation, or executor crash recovery.
8. Verify final HIBERNATED state and persist evidence.

## Proposed control flow
`Director -> infra job queue -> policy gate -> Hyperstack API -> SSH runner -> benchmark -> evidence store -> hibernate -> verify -> Quality Gate`

## First benchmark
- Alibaba LiveAvatar visual runtime.
- A100 80 GB compatibility and sustained run.
- Then Qwen conversational integration.
- Then MiniMax voice comparison.
- Measure identity stability, lip-sync, gaze/gesture quality, FPS, end-to-end latency, VRAM/GPU utilization and real infrastructure cost per hour/session.
- Product target remains a perceived-realism gate around 95/100 and economic viability for the planned subscription tiers; benchmark evidence, not provider demos, decides GO/NO-GO.

## Implementation gates
### Gate A — credentials
Fresh dedicated Hyperstack API credential and SSH credential stored in an approved server-side secret manager. No secret values committed.

### Gate B — policy
Allowlist VM identifier, permitted actions, maximum runtime, maximum estimated spend, concurrency=1, mandatory hibernation finally-handler.

### Gate C — dry run
Read-only state inspection and policy evaluation with no VM wake-up.

### Gate D — lifecycle canary
Restore -> health check -> trivial GPU command -> hibernate -> verify. No LiveAvatar yet.

### Gate E — benchmark
Install/run benchmark only after lifecycle canary passes and evidence is persisted.

## Failure policy
Any uncertain state, auth error, SSH failure, timeout, budget breach, or missing telemetry causes STOP-NEW-WORK and attempts safe hibernation. If final state cannot be verified, escalate HELP and do not launch another GPU job.

## Non-goals for this branch
- Production customer workloads.
- Multi-GPU autoscaling.
- Autonomous infrastructure purchasing.
- Merging into Director core before isolated QA.
