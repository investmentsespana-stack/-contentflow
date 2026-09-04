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
- Existing pending RARA reviews are intended to drain serially under cycles that start on v73.
- A `contentflow-auto-loop` v72 invocation had already started at 02:35 UTC before v73 became active and completed at 02:35:55 UTC. That legacy in-flight v72 invocation subsequently emitted a final two-RARA pair that completed around 02:36:16–02:36:17 UTC. This pair is attributable to the already-running v72 process and is not evidence that v73 itself scheduled two workers.
- A standalone statement timeout was also visible at 02:35:13 UTC. Because it occurred while the legacy v72 cycle was still in flight, final lock-contention closure must be judged from the first complete cycle that starts on v73, not from this overlap window.

## Blockers / limitations

- Direct ad-hoc SQL inspection of backlog/task rows was blocked by the available tool safety layer in this run, so this report does not assert fresh F02-F09 row-level states beyond evidence actually observed through the control-plane/runtime surfaces.
- The first full v73-started review cycle had not completed at the time of this report. Therefore no claim is made yet that every statement timeout is resolved.

## Tasks completed in this block

1. Diagnosed repeated RARA concurrency and DB lock contention.
2. Identified the fanout source in the auto-loop.
3. Patched the repository structurally.
4. Deployed `contentflow-auto-loop` v73 to production.
5. Distinguished the last in-flight v72 RARA pair from future v73 behavior.
6. Preserved all Social Ops publication and GPU safety gates.

## Reassignable / parallel work

CPU evidence collection, editing preparation, deterministic QA and non-GPU handoff work may continue in parallel. RARA review application should remain serialized until lock telemetry is clean across subsequent v73 cycles.

## Next step

Observe the first complete `contentflow-auto-loop` cycle whose invocation starts on v73. If RARA appears at most once from that cycle and ShareLock waits disappear, retain serialization. If statement timeouts persist without duplicate RARA, identify the exact remaining lock holder / query path and repair that component rather than reopening RARA parallelism.
