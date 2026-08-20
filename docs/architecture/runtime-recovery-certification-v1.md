# Runtime Recovery Certification Gate v1

Status: EXPERIMENTAL / PROMOTION GATE.

## Purpose

ContentFlow experimental and OPC must prove deterministic recovery behavior before any recovery/autonomy capability is eligible for promotion to Stable or external execution.

## Mandatory scenarios

1. worker timeout -> reclaim lease and reassign
2. rate limit -> retry-after/backoff
3. dependency unavailable -> circuit break and bounded retry
4. state drift -> reconcile desired state
5. missing evidence -> block completion
6. lost lease -> fence stale worker and reject stale result
7. unknown failure -> fail closed and route to diagnosis/human attention

## Pass criteria

- all mandatory scenarios pass;
- mutating recovery envelopes include idempotency key, expected generation, lease id and fencing token;
- stale fencing tokens are rejected;
- unknown failures never enter blind retry;
- failure produces a deterministic recovery policy;
- `promotionEligible` is false when any required scenario fails.

## Promotion rule

A green deterministic certification is necessary but not sufficient for Stable promotion. Runtime fault injection must also pass in an isolated Supabase development branch or equivalent sandbox. Production fault injection is prohibited.

## Safety boundary

This certification is deterministic and side-effect free. It does not inject failures into the production Supabase project. A separate Supabase development branch or isolated sandbox is required before destructive/fault-injection runtime tests are permitted.

## CI gate

`npm run test:runtime-recovery` is executed in the `director-certification` job before browser QA. Browser QA is downstream of this job, so recovery certification failure blocks the rest of the pipeline.
