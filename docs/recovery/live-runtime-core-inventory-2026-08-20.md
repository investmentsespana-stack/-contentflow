# ContentFlow live runtime core inventory — 2026-08-20

Source: Supabase project `koqpyfvnprmirqviafzq` (`ContentFlow AI`, ACTIVE_HEALTHY).

This inventory is for recoverability/version-control closure. It does not modify production.

## Already versioned before this recovery pass

- contentflow-app
- contentflow-auto-loop
- contentflow-director-contract-observe
- contentflow-director-control
- contentflow-rara
- recovery-director-sandbox
- recovery-worker-sandbox
- opc-director-contract-observe

## Exported from the currently deployed production version in this pass

| Function | Live version | Live SHA-256 | verify_jwt | Repository path |
|---|---:|---|---|---|
| contentflow-throughput-recovery | 9 | `b64f284ad8800ef93f87886794c26ea1ea9dac7219488672ad7dfb280c195bdc` | true | `supabase/functions/contentflow-throughput-recovery/index.ts` |
| contentflow-adaptive-dispatcher | 8 | `f0c617d6730074e2e1960abfcbebc24feec78b66d37606a74e503441c50e4016` | true | `supabase/functions/contentflow-adaptive-dispatcher/index.ts` |

## Remaining runtime-core exports — next recovery batch

These are active in production and not yet represented as top-level function directories in `main` at the start of this pass:

- contentflow-director — v16 — `a030e6cafb7781f9ad93438ca1a2c49a9b1ea92c30d23787d50c9b8c9e772cba`
- contentflow-orchestrator — v13 — `908744c44c1b63b68509a50823fe3b4324642524d7878e31607962e08d708541`
- contentflow-submit — v14 — `7a4805cc11523934d8c1d804c3c99bcee5abfcfb6ef97c6c9ba6cc6ab97fa42e`
- contentflow-status — v10 — `f3e4054eab3bb2c8b3acc1691edf1a8936ab484c1bd0a30e60eaed63374be471`
- contentflow-agent-team — v15 — `93507ca51b85223ebbfeafbfd8cbf64a2da022884d4b964bceeecb7d2d4d30b1`
- contentflow-builder-agent-runner-v2 — v10 — `1e9cd489b2b7fdb795b80dda05687a17eeab11b92278ea775641aeb841144973`
- contentflow-dispatch-executor-v2 — v6 — `824e30f6145937bcbd44f739be10c808c8227cbec087b1d5847f711f46b02dbf`
- contentflow-capacity-planner — v7 — `3199befb131e018dc57b6d37db8ad802c7a778f658037febef59da1444f40fea`
- contentflow-evidence-tool-runner — v1 — `49aff4d93de74a37e18c860faa9bbe51ee22729d5491e717b7e4b327985576de`

## Secondary/live utility functions still requiring classification

The production project also contains active smoke-test, benchmark, e2e, builder sprint, maintenance, inventory, QA-kick and other utility functions. They must be classified as `required-for-rebuild`, `test-only`, `one-shot/obsolete`, or `replaceable` before deciding whether every one belongs in the canonical recovery set. The recovery closure criterion is rebuildability, not blindly copying every historical utility.

## Recovery acceptance rule

Issue #1 remains open until:

1. all `required-for-rebuild` live functions are versioned;
2. canonical migrations/policies/cron are versioned;
3. a recovery snapshot is successfully produced;
4. a clean isolated restore is verified and passes Director runtime/QA certification.
