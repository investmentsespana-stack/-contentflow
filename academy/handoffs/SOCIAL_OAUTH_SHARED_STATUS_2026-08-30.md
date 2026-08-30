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

## YouTube — DURABLY CONNECTED AND CERTIFIED

Status: CONNECTED_PERSISTED / CERTIFIED 2026-08-30

Verified end-to-end evidence:
- Real Google OAuth authorization completed against the intended YouTube account.
- Exact YouTube channel was discovered and verified by YouTube Data API before persistence.
- Verified channel title: ruben espana.
- Granted scopes verified: https://www.googleapis.com/auth/youtube and https://www.googleapis.com/auth/youtube.upload.
- Refresh token was received and durable persistence succeeded.
- Final runtime schema: nexo.youtube.oauth.persistence.v1.
- Final runtime status: connected_persisted.
- refreshTokenPersisted: true.
- Final persistence check: 2026-08-30T17:56:05.305Z.
- No Google/YouTube access token or refresh token was displayed or committed to GitHub.

Durable storage:
- Server-side vault: Supabase project ContentFlow AI.
- Vault table: public.youtube_oauth_token_vault.
- RLS enabled; anon/authenticated access revoked.
- Persistence RPC restricted to service_role.
- OAuth credentials/tokens are encrypted before database persistence.
- Vercel production runtime holds the required server-side Supabase secret; the secret value is not recorded here.

Recovery behavior:
- The runtime can refresh an expired Google access token using the persisted refresh-token path before channel verification/persistence.
- OAuth callback and persistence remain fail-closed on verification/storage failure.

Canonical runtime files:
- api/youtube/oauth/start.js
- api/youtube/oauth/callback.js
- api/youtube/diagnostic.js
- api/youtube/demo.js

Current granted capabilities:
- YouTube account management under the granted `youtube` scope.
- Video upload under `youtube.upload`.
- Permanent deletion is NOT certified or authorized by this handoff; project no-permanent-deletion guardrail remains in force.

Continuation rule for all workers: DO NOT redo YouTube OAuth setup. Treat YouTube as durably connected unless a fresh runtime/vault check proves otherwise. Never request or expose OAuth client secrets, Supabase service keys, access tokens, or refresh tokens.

## Meta / Facebook / Instagram

Preserve previous certified state and do not reopen or redo Meta work from this handoff alone.

Known canonical Meta assets from prior handoffs:
- Facebook Page: Cygnus Academy AI
- Page ID: 102575905973808
- Instagram target: @cygnusacademyai
- Instagram ID: 17841455070447156
- Canonical Meta app: Cygnus Academy AI-Nexo
- App ID: 1784797469372306

## Director / agent execution state

Latest reported Academy control-plane state during this pass:
- 10 workers ready
- 0 running
- 0 dispatchable
- 0 mismatches
- 0 warnings
- waiting work is external-dependency bound, not an internal repairable stall

Do not force artificial retries or work when dispatchable=0 and blockers are external.

## Relevant implementation/evidence commits

TikTok sandbox/production separation and diagnostics:
- 300ce8324b3dc92f44eefea1c1213174afe515ee
- d2e7e37ad332b77b313f1dcc1a54cf4054ed7409
- 6c0f05423c44ea4b8113fd71156991a7ba74ab21

Research / operational handoff:
- ac0e58efa2045d5272e75266f9f0a7067dbab9be

YouTube OAuth implementation/certification history:
- 39d31e44af27c6862ae87e3121c280e97b54ee46
- 4609c8d44b27333405a95f1bf46db11dc026aece
- 8b8c9ee33877878fe9a6ea2ce2e2ed7f0376141b
- ca8795f921d5a75854425c1f47c705b75f85def9
- a6ee9b1556f1fa6ca42335433836c694dfc6d0a6

## Cross-channel continuation rule

Any channel or worker continuing this work should start by reading this file and the canonical Academy handoff before changing OAuth configuration. Do not redo completed setup. First verify live diagnostic state; then execute only the next unresolved gate.
