# Jarvis Fresh Context v6 — rollback runbook

This directory is the pre-deploy recovery point for PR #130.

## Rollback order
1. Stop any rollout of Jarvis Fresh Context v6.
2. Redeploy the backed-up `jarvis-director-bridge` source to the original slug.
3. Redeploy the backed-up `jarvis-project-state-gateway` source to the original slug.
4. Verify both functions answer with the pre-deploy schemas.
5. Only if the database feature itself must be removed, review and manually execute `database/rollback.sql`.
6. Re-run Jarvis Desktop Certification and production drift/parity checks.

## Safety
The rollback SQL is intentionally not wired to CI or any automatic workflow.
