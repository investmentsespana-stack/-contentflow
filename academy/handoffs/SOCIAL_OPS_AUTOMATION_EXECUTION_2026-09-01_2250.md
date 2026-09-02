# Social Ops — Cygnus · Canonical execution report

Date: 2026-09-01
Block: TikTok OAuth state browser/session binding
Status: EXECUTED / SAFE / NO OAUTH / NO UPLOAD / NO PUBLICATION

## Assignment detected

The latest canonical Social Ops handoff left a safe, executable repository-side hardening task while TikTok remains blocked on external Target User authorization:

- bind OAuth `state` to the initiating browser/session;
- consume that binding in the callback;
- preserve mode-bound, signed, short-lived state;
- do not initiate OAuth, upload, or publication;
- keep P1 approval-only;
- leave Meta blocked unless an already-authorized reusable session/token appears.

No newer Social Ops assignment superseding these guardrails was found in the reviewed GitHub issue stream or recent Social Ops handoffs.

## Evidence reviewed

`api/tiktok/oauth/start.js` previously generated a signed, short-lived, nonce-bearing and mode-bound state, but did not bind that state to the initiating browser/session.

`api/tiktok/oauth/callback.js` previously validated signature, age, nonce and mode, but accepted any otherwise-valid state without requiring a browser-side one-time binding.

The prior canonical handoff explicitly reassigned this as defense-in-depth work for login-CSRF/replay resistance.

## Safe correction executed

### Commit 1

`8252656e94c406906acfb85f696f09c9806ce029`

Updated `api/tiktok/oauth/start.js` to:

1. generate a cryptographically random 32-byte browser binding;
2. store only the raw binding in a short-lived `HttpOnly; Secure; SameSite=Lax` cookie scoped to `/api/tiktok/oauth`;
3. include only SHA-256(binding) inside the signed OAuth state payload;
4. retain existing issuance time, random nonce and environment mode binding;
5. keep the state HMAC-signed with the environment-specific TikTok client secret;
6. retain the 10-minute state lifetime.

### Commit 2

`0a37146a3da4e530c9604a8666db8375300fa126`

Updated `api/tiktok/oauth/callback.js` to:

1. require the initiating-browser binding cookie before accepting state;
2. recompute SHA-256(binding) and compare it in constant time with the binding embedded in signed state;
3. preserve existing signature, age, nonce and mode validation;
4. reject missing/mismatched/unbound state fail-closed before token exchange;
5. clear/consume the binding cookie on success and on OAuth/error paths;
6. preserve encrypted TikTok demo-session handling and secret/token redaction;
7. preserve the existing TikTok session cookie while appending the state-cookie clear operation safely.

## Guardrails / QA

- NO TikTok OAuth initiated: PASS.
- NO authorization code exchange initiated: PASS.
- NO content upload: PASS.
- NO publication: PASS.
- NO account creation: PASS.
- NO token/secret material recorded: PASS.
- State signature validation retained: PASS.
- State expiry validation retained: PASS.
- Nonce validation retained: PASS.
- Sandbox/production mode binding retained: PASS.
- Initiating-browser binding added: PASS at repository contract level.
- Binding cookie is short-lived, HttpOnly, Secure and SameSite=Lax: PASS.
- Binding is consumed/cleared in callback: PASS.
- Missing/mismatched binding fails before token exchange: PASS.

No deployed runtime OAuth flow was executed because that would violate the current guardrail and external-authorization boundary.

## Current blockers

TikTok remains:

`BLOCKED_EXTERNAL_TARGET_USER_AUTHORIZATION`

The repository path is now additionally hardened, but real account certification still requires the external TikTok Target User authorization step. Once that external gate is available, execute exactly one certification OAuth flow and verify the exact account identity and granted scopes; do not upload or publish during certification.

Meta remains blocked unless an already-authorized reusable write-capable Meta session/token becomes available. Do not repeat OAuth simply to satisfy a check.

## Tasks completed in this block

- Reviewed current Social Ops assignment stream and recent canonical handoff state.
- Identified the explicit uncompleted safe hardening item from the last handoff.
- Added browser/session binding to TikTok OAuth state creation.
- Added binding validation and one-time consumption to callback.
- Preserved all existing security properties and redaction behavior.
- Preserved no-OAuth/no-upload/no-publication guardrails.

## Reassignable work

1. Add automated unit/integration tests for:
   - valid browser-bound state;
   - missing state cookie rejection;
   - mismatched state cookie rejection;
   - expired state rejection;
   - sandbox/production mode mismatch rejection;
   - one-time state-cookie consumption.
2. After deployment, run a non-authorizing deployed diagnostic that verifies route availability/configuration only; do not initiate TikTok authorization.
3. When TikTok Target User authorization becomes available, run exactly one real certification OAuth flow and record exact account/scopes without exposing token material.
4. Resume Meta preflight only if existing reusable authorization appears.
5. Keep P1 `READY_FOR_APPROVAL / NOT_UPLOADED / NOT_PUBLISHED` until separate human publication approval.

## Director next step

Record OAuth-state browser binding as completed at source commits `8252656e94c406906acfb85f696f09c9806ce029` and `0a37146a3da4e530c9604a8666db8375300fa126`. The next safe repository-side task is automated coverage for state binding and session-mode contracts. External TikTok Target User authorization remains the only gate to real account certification. Do not weaken the publication gate.