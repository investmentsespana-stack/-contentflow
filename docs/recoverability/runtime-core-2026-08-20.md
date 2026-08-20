# Runtime core recoverability — 2026-08-20

Verified directly against Supabase production.

| Function | Version | verify_jwt | SHA-256 | Status |
|---|---:|---|---|---|
| contentflow-director | 16 | true | a030e6cafb7781f9ad93438ca1a2c49a9b1ea92c30d23787d50c9b8c9e772cba | ACTIVE |
| contentflow-orchestrator | 13 | true | 908744c44c1b63b68509a50823fe3b4324642524d7878e31607962e08d708541 | ACTIVE |
| contentflow-agent-team | 15 | true | 93507ca51b85223ebbfeafbfd8cbf64a2da022884d4b964bceeecb7d2d4d30b1 | ACTIVE |
| contentflow-builder-agent-runner-v2 | 10 | true | 1e9cd489b2b7fdb795b80dda05687a17eeab11b92278ea775641aeb841144973 | ACTIVE |
| contentflow-dispatch-executor-v2 | 6 | true | 824e30f6145937bcbd44f739be10c808c8227cbec087b1d5847f711f46b02dbf | ACTIVE |
| contentflow-capacity-planner | 7 | true | 3199befb131e018dc57b6d37db8ad802c7a778f658037febef59da1444f40fea | ACTIVE |

The full live sources for all six critical runtime functions were retrieved successfully from Supabase during the recoverability audit. Runtime credentials are read from environment variables / protected runtime configuration rather than requiring repository-committed secrets.

Critical runtime recovery inventory is now complete for the Director/orchestration/execution path. Remaining recoverability work is database-side: sanitized current-state schema export, constraints/indexes/RLS/policies/functions, runtime-control restore, and clean-environment validation.

Restore note: historical database migrations must not be replayed blindly because the audit found historical production endpoints/tokens embedded in some old migration bodies. Restore should use sanitized current-state schema plus externally supplied secrets.
