# Stable Certification Receipt

Stable promotion is considered formally recertified only when the `panel-qa-v1` workflow runs on a `push` to `main` and all required jobs succeed.

When `director-certification` and the complete `browser-matrix` succeed, the workflow publishes a commit status on the Stable SHA:

- context: `contentflow/stable-recertification`
- state: `success`

The receipt is intentionally not published for pull-request runs, partial runs, failed certification jobs, or failed browser jobs. Absence of the success receipt must not be interpreted as a successful Stable recertification.

The receipt is observational evidence only. It does not grant runtime authority, bypass project boundaries, change OPC executability, or replace deterministic certification artifacts.
