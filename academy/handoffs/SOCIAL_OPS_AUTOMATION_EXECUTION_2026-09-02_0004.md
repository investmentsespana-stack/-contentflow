# Social Ops — Cygnus · Canonical execution report

Date: 2026-09-02
Block: TikTok OAuth state automated contract coverage
Status: EXECUTED / SAFE / NO OAUTH / NO UPLOAD / NO PUBLICATION

## Assignment detected

Reviewed the current Social Ops control-plane evidence and latest canonical handoff. No newer Social Ops assignment superseded the previous handoff. The latest handoff explicitly reassigned the next safe repository-side task: automated coverage for the browser-bound TikTok OAuth state contract, including valid binding, missing/mismatched binding, expiration, environment-mode mismatch, and one-time cookie consumption behavior.

## Evidence reviewed

- `api/tiktok/oauth/start.js` currently issues signed, short-lived, nonce-bearing, environment-bound state and binds it to a random browser cookie through SHA-256.
- `api/tiktok/oauth/callback.js` validates signature, age, nonce, environment mode and browser binding before token exchange, and clears the binding cookie on callback paths.
- The prior canonical handoff `SOCIAL_OPS_AUTOMATION_EXECUTION_2026-09-01_2250.md` assigned automated tests as the next safe repository task.
- No TikTok real-user authorization or publication approval was present.

## Safe execution completed

### Commit 1

`82d5b3ed185dfc4ad149a561a2478b5fd6eddcd4`

Added `tests/tiktok-oauth-state.test.mjs` with Node built-in test coverage for:

1. start route creates a signed two-part state and short-lived hardened binding cookie;
2. cookie attributes include `HttpOnly`, `Secure`, `SameSite=Lax`, and `Max-Age=600`;
3. valid browser-bound state reaches the mocked token/user-info path and clears the state-binding cookie;
4. missing browser cookie rejects with HTTP 400 before any token exchange;
5. mismatched browser cookie rejects before any token exchange;
6. correctly re-signed but expired state rejects before any token exchange;
7. sandbox-issued state is rejected if callback runtime is production;
8. successful callback preserves encrypted demo-session behavior while consuming the browser-binding cookie.

All external TikTok calls in the positive-path test are local mocks. Invalid-path tests explicitly assert zero network/token-exchange calls.

### Commit 2

`f56e5680bfa333daa2386612c79c472b1e6ee3c1`

Added package script:

`npm run test:tiktok-oauth-state`

which maps to:

`node --test tests/tiktok-oauth-state.test.mjs`

## Execution evidence / limits

The repository test contract and runnable npm script are now committed. A direct local execution attempt could not clone GitHub from the isolated worker because DNS/network access to `github.com` is unavailable in that worker. The GitHub connector available for this run supports repository reads/writes and workflow inspection/retry, but does not expose a workflow-dispatch action for starting a fresh CI run. Therefore this block is certified as **TEST COVERAGE IMPLEMENTED**, not falsely promoted to **CI-PASSED**.

No real OAuth flow was initiated to compensate for the missing runner, because that would violate the external-authorization guardrail.

## Guardrails

- NO TikTok OAuth initiated: PASS.
- NO authorization-code exchange against TikTok: PASS.
- NO upload: PASS.
- NO publication: PASS.
- NO account creation: PASS.
- NO secret/token values recorded: PASS.
- P1 publication gate unchanged: PASS.
- Invalid OAuth-state paths designed to fail before token exchange: covered by committed tests.

## Current blockers

TikTok real account certification remains:

`BLOCKED_EXTERNAL_TARGET_USER_AUTHORIZATION`

Automated test code is committed but still needs execution in a runner with repository checkout capability before being promoted to CI-certified PASS.

Meta remains blocked unless an already-authorized reusable write-capable session/token becomes available. Do not repeat OAuth merely to satisfy a preflight.

## Tasks completed

- Reviewed current Social Ops control-plane / latest handoff state.
- Confirmed no newer assignment supersedes the TikTok hardening track.
- Implemented automated OAuth-state contract tests.
- Added an explicit package script for deterministic execution.
- Preserved no-OAuth/no-upload/no-publication guardrails.

## Reassignable work

1. Run `npm run test:tiktok-oauth-state` in GitHub Actions or another trusted checkout-capable runner and record exact pass/fail evidence.
2. If a failing contract appears, repair source or test assumptions without weakening state validation.
3. Run a deployed non-authorizing route/configuration diagnostic only; do not begin TikTok authorization.
4. When TikTok Target User authorization is available, execute exactly one certification OAuth flow, verify exact account identity and granted scopes, and do not upload/publish during certification.
5. Resume Meta preflight only if existing reusable authorization appears.
6. Keep P1 `READY_FOR_APPROVAL / NOT_UPLOADED / NOT_PUBLISHED` until separate human publication approval.

## Director next step

Record TikTok OAuth state automated coverage as implemented at commits `82d5b3ed185dfc4ad149a561a2478b5fd6eddcd4` and `f56e5680bfa333daa2386612c79c472b1e6ee3c1`. Next safe step is runner-side execution of `npm run test:tiktok-oauth-state`; do not promote to CI PASS until that evidence exists. Real TikTok certification remains gated only by external Target User authorization, and the publication gate remains unchanged.
