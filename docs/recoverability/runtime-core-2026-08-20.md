# Runtime core recoverability — 2026-08-20

Verified directly against Supabase production.

| Function | Version | verify_jwt | SHA-256 | Status |
|---|---:|---|---|---|
| contentflow-director | 16 | true | a030e6cafb7781f9ad93438ca1a2c49a9b1ea92c30d23787d50c9b8c9e772cba | ACTIVE |
| contentflow-orchestrator | 13 | true | 908744c44c1b63b68509a50823fe3b4324642524d7878e31607962e08d708541 | ACTIVE |

The full live sources were retrieved successfully from Supabase during the recoverability audit. They use environment variables for Supabase/Nexo credentials rather than embedding the Nexo API key in source.

Next runtime export targets: contentflow-agent-team, contentflow-builder-agent-runner-v2, contentflow-dispatch-executor-v2, contentflow-capacity-planner.

Restore note: historical database migrations must not be replayed blindly because the audit found historical production endpoints/tokens embedded in some old migration bodies. Restore should use sanitized current-state schema plus externally supplied secrets.
