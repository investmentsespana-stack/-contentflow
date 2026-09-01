# Social Ops — Cygnus · Canonical execution report

Date: 2026-09-01
Block: TikTok repository-side OAuth/session hardening
Status: EXECUTED / SAFE / NO OAUTH / NO UPLOAD / NO PUBLICATION

## Assignment detected

The latest Social Ops handoff reassigned safe repository-side work while TikTok remains blocked on external Target User authorization:

- validate OAuth callback/state handling and token redaction without initiating real authorization;
- keep TikTok diagnostic under observation for regressions;
- preserve P1 as READY_FOR_APPROVAL / NOT_UPLOADED / NOT_PUBLISHED;
- do not reopen YouTube OAuth/identity work;
- only resume Meta preflight if an already-authorized reusable Meta session/token appears.

No newer Social Ops assignment superseding these guardrails was found in the reviewed control-plane/handoffs.

## Evidence reviewed

### OAuth start

`api/tiktok/oauth/start.js`

- selects production vs sandbox credentials from `TIKTOK_OAUTH_MODE`;
- creates a random 24-byte nonce;
- signs state with HMAC-SHA256 using the selected mode client secret;
- includes mode and issuance timestamp in state;
- requests only `user.info.basic` and `video.upload`.

### OAuth callback

`api/tiktok/oauth/callback.js`

- validates state signature, maximum age, nonce length, and expected mode;
- exchanges authorization code server-side;
- obtains user info server-side;
- encrypts access/refresh token session data with AES-256-GCM using the selected mode client secret;
- saves only the encrypted session in an HttpOnly + Secure + SameSite=Lax cookie;
- stores `mode` inside the encrypted session payload;
- presents a token fingerprint rather than the token itself;
- sanitizes token/client-secret-like material from reported errors.

### Content posting upload path

`api/tiktok/upload.js` had a concrete mode inconsistency:

- OAuth start/callback selected `TIKTOK_SANDBOX_CLIENT_SECRET` when `TIKTOK_OAUTH_MODE=sandbox`;
- upload always attempted to decrypt the encrypted session with `TIKTOK_CLIENT_SECRET`.

This meant a legitimate sandbox session could fail upload-session decryption, or the endpoint could return runtime-credentials-missing when only sandbox credentials were configured.

## Safe correction executed

Commit: `9aae54bb95495b9df26888cc95cc882d87c24ff4`

Updated `api/tiktok/upload.js` so that:

1. upload resolves runtime mode from the same `TIKTOK_OAUTH_MODE` contract used by start/callback;
2. sandbox mode uses `TIKTOK_SANDBOX_CLIENT_SECRET`;
3. production mode uses `TIKTOK_CLIENT_SECRET`;
4. an encrypted session carrying a different `mode` is rejected before token use;
5. existing token/upload URL redaction remains intact;
6. logs now include non-sensitive runtime mode only.

No OAuth request, token exchange, TikTok upload, TikTok inbox transfer, or publication was initiated during this correction.

## QA / guardrails

- NO OAuth initiated: PASS.
- NO content upload: PASS.
- NO publication: PASS.
- NO account/page creation: PASS.
- NO credential or token material recorded: PASS.
- Secret mode consistency: FIXED.
- Session mode mismatch: FAIL-CLOSED.
- Token-looking values / TikTok upload URLs in errors: REDACTED.
- P1 publication gate rechecked from `academy/social/SOCIAL_OPS_P1_READY_FOR_APPROVAL_2026-08-31.md`: still `READY_FOR_APPROVAL / NOT_UPLOADED / NOT_PUBLISHED`.

## Residual security hardening observation

The OAuth `state` is signed, short-lived, nonce-bearing, and mode-bound, which prevents tampering and stale-state reuse outside the accepted window. It is not currently bound to a separate initiating-browser/session cookie or one-time server-side state record. This is not promoted here as an observed compromise, but it remains a useful defense-in-depth hardening task for login-CSRF/replay resistance.

## Runtime evidence limitation

A fresh deployed-runtime TikTok diagnostic response was not obtained in this block. Therefore this report does NOT claim a new post-commit deployment/runtime PASS. The last canonical diagnostic evidence remains the prior Social Ops handoff until deployment/runtime is freshly verified.

## Current blocker

TikTok remains:

`BLOCKED_EXTERNAL_TARGET_USER_AUTHORIZATION`

The backend can be prepared and hardened without authorization, but exact user/account certification requires the external Target User authorization step. The guardrail remains: after authorization, run exactly one certification OAuth flow; do not upload or publish content as part of certification.

Meta remains externally blocked unless an already-authorized reusable write-capable Meta session/token becomes available. No OAuth should be repeated merely to satisfy a check.

## Tasks completed in this block

- Reviewed current Social Ops control-plane/handoff assignment state.
- Audited TikTok OAuth start state construction.
- Audited TikTok callback validation, encrypted session handling, and error redaction.
- Audited TikTok upload session/token handling.
- Detected sandbox/production session-secret mismatch.
- Corrected the mismatch and added fail-closed runtime/session mode verification.
- Reconfirmed P1 remains not uploaded and not published.
- Preserved all platform publication and OAuth guardrails.

## Reassignable work

1. Add initiating-browser/session binding for TikTok OAuth `state` (for example a short-lived HttpOnly state cookie or one-time server-side state record) and validate/consume it in callback.
2. Add unit/integration coverage for sandbox vs production encrypted-session compatibility and mode mismatch rejection.
3. Run fresh deployed diagnostic after the new upload-path commit is deployed; record exact response without exposing secrets.
4. When TikTok Target User authorization becomes available, execute exactly one OAuth certification and verify granted scopes/account identity; keep upload/publication disabled.
5. Resume Meta preflight only when existing reusable authorization evidence appears; fail closed otherwise.

## Director next step

Treat repository-side TikTok OAuth/session consistency as corrected at source commit `9aae54bb95495b9df26888cc95cc882d87c24ff4`. Next safe technical action is deployment/runtime verification plus defense-in-depth state binding/tests. The external Target User authorization remains the only gate to real TikTok account certification. P1 remains approval-only and must not be uploaded or published without separate human authorization.
