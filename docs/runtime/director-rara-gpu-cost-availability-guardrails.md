# Director/RARA GPU Cost & Availability Guardrails

Status: PERMANENT
Scope: Hyperstack and any future paid GPU provider
Owner: Director Orchestrator + RARA

## Rule 1 — Dynamic IP only
Paid GPU workers MUST NOT depend on a fixed public IP. Every lifecycle operation must discover the current public address from the provider API at runtime. A public IP may be used for the current session but MUST NOT become durable configuration.

## Rule 2 — Learned bad restore patterns are not retried
When a VM/provider lifecycle demonstrates a repeated failure signature such as `ACTIVE + NO FLOATING IP`, Director/RARA must persist that signature and block the same restore strategy from being repeated automatically. Recovery must change strategy (for example: fresh replacement provisioning with explicit floating-IP assignment) rather than spending more paid time repeating the same failed path.

Current learned block:
- Hyperstack VM 997313
- Signature: `ACTIVE + NO FLOATING IP`
- Automated restore: PROHIBITED

## Rule 3 — No paid GPU time for infrastructure waiting
`ACTIVE` is not equivalent to `READY_FOR_WORK`. Paid GPU time is justified only after useful-work readiness is confirmed.

Useful-work readiness requires all of:
- provider state ACTIVE;
- runtime-discovered network address available;
- SSH/remote executor connectivity passes;
- GPU probe passes (`nvidia-smi` or provider-equivalent);
- a valid task can be dispatched.

If ACTIVE is reached but infrastructure remains unavailable beyond the configured short grace period, Director/RARA must stop the paid state (hibernate/stop/terminate according to provider policy) and record evidence.

Default Hyperstack grace periods:
- ACTIVE without public IP: 180 seconds maximum;
- public IP without SSH readiness: 180 seconds maximum.

## Dispatch safety
Paid GPU workflows MUST NOT be triggered by ordinary repository pushes. They require explicit orchestration/dispatch intent. Failure cleanup must prefer returning the worker to a non-billable or lowest-billable safe state.

## Learning requirement
Every cost-triggered shutdown or lifecycle failure must create machine-readable evidence with: provider, VM/worker ID, failure signature, state transitions, elapsed paid-wait time, recovery action, and final state. Director/RARA must consult this evidence before choosing a future lifecycle strategy.
