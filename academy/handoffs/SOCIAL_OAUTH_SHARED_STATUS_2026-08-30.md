# Cygnus Academy AI — Shared Social OAuth Status

Date: 2026-08-30
Repository: investmentsespana-stack/-contentflow
Purpose: canonical cross-channel handoff so Academy / Director / ContentFlow / social-integration workstreams share the same verified state and do not repeat completed work.

## Operating rules

- GitHub is the source of truth for handoffs and implementation state.
- Use official OAuth/API flows only.
- Never store or paste passwords, MFA codes, cookies, access tokens, refresh tokens, client secrets, app secrets or private keys in chat or repository files.
- Do not declare a social account connected until the exact target account/channel is verified by the platform API and the required scopes are confirmed.
- Do not publish, delete, archive or modify social content during OAuth verification unless a separately approved task explicitly authorizes it.
- Do not duplicate apps/accounts/integrations when a canonical one already exists.

## TikTok — current verified state

Status: BACKEND READY / PRODUCTION CREDENTIAL FAMILY ACTIVE / SANDBOX NOT YET CERTIFIED

Verified runtime diagnostic:
- HTTP 200
- schema: nexo.tiktok.runtime.preflight.v2
- status: ready
- mode: production
- clientKeyConfigured: true
- clientSecretConfigured: true
- redirectUri: https://investmentsespana.space/api/tiktok/oauth/callback
- scopes: user.info.basic, video.upload

Implemented behavior:
- Production and Sandbox credential families are separated.
- TIKTOK_OAUTH_MODE selects production vs sandbox.
- Sandbox variables are supported independently from production variables.
- OAuth state includes the selected mode and is cryptographically signed with the matching credential family.
- Callback validates the same credential family/mode before token exchange.
- Safe runtime diagnostics do not expose secrets or tokens.

Canonical runtime files:
- api/tiktok/oauth/start.js
- api/tiktok/oauth/callback.js
- TikTok diagnostic endpoint under /api/tiktok

Important: do NOT mark TikTok Sandbox connected yet. Current runtime is still mode=production.

Next legitimate gate for TikTok:
1. Complete/verify Sandbox Target User authorization in TikTok Developer Portal.
2. Add Sandbox Client Key and Client Secret directly to Vercel secrets/environment without posting them in chat.
3. Set TIKTOK_OAUTH_MODE=sandbox for the intended demo runtime.
4. Redeploy once.
5. Re-run safe diagnostic and require mode=sandbox + both sandbox credentials configured.
6. Run Login Kit OAuth with the authorized Sandbox Target User.
7. Verify user.info.basic + video.upload were actually granted.
8. Only then record Sandbox as connected and proceed to the real review demo video.

## YouTube — current verified state

Status: RUNTIME READY / OAuth AUTHORIZATION OF EXACT CHANNEL STILL PENDING

Verified runtime diagnostic:
- HTTP 200
- schema: nexo.youtube.runtime.preflight.v1
- status: ready
- clientIdConfigured: true
- clientSecretConfigured: true
- redirectUri: https://investmentsespana.space/api/youtube/oauth/callback

Google Cloud state already completed:
- Project: Cygnus Academy AI-YouTube
- YouTube Data API v3 enabled
- Google Auth Platform configured for External users
- OAuth web client created
- Authorized JavaScript origin: https://investmentsespana.space
- Authorized redirect URI: https://investmentsespana.space/api/youtube/oauth/callback
- YOUTUBE_CLIENT_ID and YOUTUBE_CLIENT_SECRET are now present in Production runtime

Implemented runtime behavior:
- Secure signed OAuth state
- Google authorization-code exchange server-side
- access_type=offline and prompt=consent for refresh-token eligibility
- channel verification through YouTube Data API channels.list mine=true
- granted scopes captured
- tokens are not displayed
- encrypted demo session only after channel verification

Canonical runtime files:
- api/youtube/oauth/start.js
- api/youtube/oauth/callback.js
- api/youtube/diagnostic.js
- api/youtube/demo.js

Current requested scopes in code:
- https://www.googleapis.com/auth/youtube
- https://www.googleapis.com/auth/youtube.upload

Permission note:
- Upload capability is covered by youtube.upload.
- Before certifying explicit delete-video capability, align the final scope set with current Google documentation and the exact operation contract. Do not claim deletion certification until a real authorized channel and the final granted scopes are verified.

Next legitimate gate for YouTube:
1. Run real OAuth authorization from the intended Google account/channel.
2. Verify the exact returned YouTube channel ID/title before persistence.
3. Verify granted scopes.
4. Confirm refresh token receipt/secure storage strategy.
5. Only then declare durable YouTube connection.
6. No upload/delete test should be performed unless separately authorized.

## Meta / Facebook / Instagram

No new runtime evidence was produced during this TikTok/YouTube pass. Preserve previous certified state and do not reopen or redo Meta work from this handoff alone.

Known canonical Meta assets from prior handoffs:
- Facebook Page: Cygnus Academy AI
- Page ID: 102575905973808
- Instagram target: @cygnusacademyai
- Instagram ID: 17841455070447156
- Canonical Meta app: Cygnus Academy AI-Nexo
- App ID: 1784797469372306

Meta remains separate from the TikTok/YouTube work described here.

## Director / agent execution state

Latest reported Academy control-plane state during this pass:
- 10 workers ready
- 0 running
- 0 dispatchable
- 0 mismatches
- 0 warnings
- waiting work is external-dependency bound, not an internal repairable stall

Do not force artificial retries or work when dispatchable=0 and blockers are external.

## Recent implementation commits to preserve

TikTok sandbox/production separation and diagnostics:
- 300ce8324b3dc92f44eefea1c1213174afe515ee
- d2e7e37ad332b77b313f1dcc1a54cf4054ed7409
- 6c0f05423c44ea4b8113fd71156991a7ba74ab21

Research / operational handoff:
- ac0e58efa2045d5272e75266f9f0a7067dbab9be

Latest runtime-status evidence handoff:
- 96e2fa87aa90b1ccfc17ae35399451c04af69b46

YouTube OAuth implementation commits already deployed earlier:
- 39d31e44af27c6862ae87e3121c280e97b54ee46
- 4609c8d44b27333405a95f1bf46db11dc026aece
- 8b8c9ee33877878fe9a6ea2ce2e2ed7f0376141b
- 7ba2eefcbc067004ffbc3a833a6a93a57e60fd19

## Cross-channel continuation rule

Any channel or worker continuing this work should start by reading this file and the canonical Academy handoff before changing OAuth configuration. Do not redo completed setup. First verify live diagnostic state; then execute only the next unresolved gate.
