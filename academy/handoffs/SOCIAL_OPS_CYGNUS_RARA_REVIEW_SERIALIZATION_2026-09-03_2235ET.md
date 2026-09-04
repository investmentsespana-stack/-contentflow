# Social Ops — Cygnus · RARA review serialization root repair

Timestamp: 2026-09-03 22:35 ET / 2026-09-04 02:35 UTC
Scope: control-plane / Social Ops monitoring, especially preserving F02-F09 safety constraints.

## Evidence observed

- Production Supabase project: `koqpyfvnprmirqviafzq` (`ContentFlow AI`), ACTIVE_HEALTHY.
- Edge logs repeatedly showed two concurrent `contentflow-rara` invocations in the same review window, including clusters around 02:21, 02:26 and 02:31 UTC.
- Matching Postgres logs showed `ShareLock` waits and `canceling statement due to statement timeout` during those same windows.
- The deployed `contentflow-auto-loop` v72 and repository source both scheduled review workers with `reviewWorkers=Math.min(2, Number(reviews||0))`, then invoked both RARA workers concurrently with `Promise.all`.
- GitHub source repair commit: `b233e40136e7e72e941b552f2455930c92f60146` (`fix(control-plane): serialize RARA review worker under DB lock contention`).
- Production deployment: `contentflow-auto-loop` v73, ACTIVE, deployment SHA `3a3ae4e6b3875c8ed36baa15db303aab63fb9aa3b0a396a3e4fcba8d893866b9`.

## Root cause

The review lane was allowed to fan out two RARA workers concurrently. RARA's claim/review/apply-decision path performs database transactions against shared review/control-plane state. The repeated 2-worker fanout correlated directly with `ShareLock` contention and statement timeouts. This is a structural concurrency mismatch in the review lane, not a GPU problem and not a reason to weaken QA.

## Structural correction

Changed only the RARA review worker cap from 2 to 1 in `supabase/functions/contentflow-auto-loop/index.ts` and deployed that exact control change to production as v73. This serializes the shared review decision lane while leaving CPU evidence/editing/tool work parallel and leaving the Avatar GPU contract untouched.

No retry policy, QA threshold, evidence contract, publication gate, GPU scheduling rule or task-completion criterion was relaxed.

## State after correction

- Source repair committed and production v73 ACTIVE.
- No F02-F09 item was marked completed by this intervention.
- No F02-F09 media was uploaded or published.
- F10 remains HOLD.
- Shared GPU was not used.
- Existing pending RARA reviews are allowed to drain serially.
- Post-deploy observation is not yet sufficient to declare all database timeout symptoms eliminated: a standalone statement timeout was still visible at 02:35:13 UTC. In the fetched post-deploy window, no new paired RARA invocation had yet appeared. Therefore this repair is considered deployed and advancing, but final lock-contention closure remains under observation.

## Blockers / limitations

- Direct ad-hoc SQL inspection of backlog/task rows was blocked by the available tool safety layer in this run, so this report does not assert fresh F02-F09 row-level states beyond evidence actually observed through the control-plane/runtime surfaces.
- The remaining standalone timeout must be attributed before any further database-level repair. Do not assume it is RARA if it persists after serialization.

## Tasks completed in this block

1. Diagnosed repeated RARA concurrency and DB lock contention.
2. Identified the fanout source in the auto-loop.
3. Patched the repository structurally.
4. Deployed `contentflow-auto-loop` v73 to production.
5. Preserved all Social Ops publication and GPU safety gates.

## Reassignable / parallel work

CPU evidence collection, editing preparation, deterministic QA and non-GPU handoff work may continue in parallel. RARA review application should remain serialized until lock telemetry is clean across subsequent cycles.

## Next step

Observe at least the next complete auto-loop/RARA cycle. If RARA appears once per cycle and ShareLock waits disappear, retain serialization. If statement timeouts persist without duplicate RARA, identify the exact remaining lock holder / query path and repair that component rather than reopening RARA parallelism.
