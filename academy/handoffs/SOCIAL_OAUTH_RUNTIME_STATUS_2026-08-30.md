# Social OAuth runtime status — 2026-08-30

Live runtime checks executed against Production.

## YouTube

Endpoint: `https://www.investmentsespana.space/api/youtube/diagnostic`

Result:
- HTTP: 200
- schema: `nexo.youtube.runtime.preflight.v1`
- status: `ready`
- `YOUTUBE_CLIENT_ID`: configured
- `YOUTUBE_CLIENT_SECRET`: configured
- redirect URI: `https://investmentsespana.space/api/youtube/oauth/callback`
- checkedAt: `2026-08-30T13:22:38.372Z`

Interpretation: runtime credential-loading blocker is resolved. Connection is **not yet certified** until a real Google/YouTube OAuth authorization verifies the exact channel and granted scopes. No access token or refresh token is recorded in this document.

## TikTok

Endpoint: `https://www.investmentsespana.space/api/tiktok/diagnostic`

Result:
- HTTP: 200
- schema: `nexo.tiktok.runtime.preflight.v2`
- status: `ready`
- mode: `production`
- Production client key: configured
- Production client secret: configured
- redirect URI: `https://investmentsespana.space/api/tiktok/oauth/callback`
- requested scopes: `user.info.basic`, `video.upload`
- checkedAt: `2026-08-30T13:22:48.694Z`

Interpretation: Production runtime is healthy. Sandbox support exists in code, but runtime currently selects Production. Sandbox must not be declared connected until `TIKTOK_OAUTH_MODE=sandbox`, Sandbox credentials are present, and a real Target User authorization succeeds.

## Guardrails

- Do not expose client secrets, access tokens, refresh tokens, cookies, or 2FA codes in GitHub or chat.
- Do not declare a social account connected from preflight alone.
- Do not publish or delete social content during OAuth certification.
- Verify exact account/channel identity after OAuth before persistence or write-capable operations.
