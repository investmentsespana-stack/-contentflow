# TikTok + YouTube OAuth research — 2026-08-30

## Purpose

Canonical operating note for Cygnus Academy AI social integrations. No passwords, client secrets, access tokens, refresh tokens, cookies, or MFA data belong in this file.

## TikTok

Official developer flow reviewed against current TikTok documentation on 2026-08-30.

- Login Kit is OAuth 2.0. Web authorization uses `https://www.tiktok.com/v2/auth/authorize/` and exchanges the returned code server-side for access/refresh tokens.
- Client secret and refresh token must remain server-side.
- First-time app review requires a real end-to-end demo using Sandbox.
- Sandbox target users must be explicitly connected/authorized for the Sandbox.
- Content Posting draft upload requires the `video.upload` scope, and both app approval and user authorization for that scope.
- Draft upload is a two-step process: initialize upload, then PUT the media bytes to the returned upload URL. The user finishes editing/posting from TikTok inbox.
- `client_key` failures should be treated first as an environment/credential-family mismatch: Sandbox has its own client key/secret and must not silently reuse Production credentials.

### Runtime contract

ContentFlow now supports an explicit TikTok OAuth credential mode:

- `TIKTOK_OAUTH_MODE=production` uses `TIKTOK_CLIENT_KEY` + `TIKTOK_CLIENT_SECRET`.
- `TIKTOK_OAUTH_MODE=sandbox` uses `TIKTOK_SANDBOX_CLIENT_KEY` + `TIKTOK_SANDBOX_CLIENT_SECRET`.
- Safe diagnostic: `/api/tiktok/diagnostic` reports only mode, booleans, lengths, redirect URI, and scopes; it never returns the credential values.

### Next human step

Complete/confirm Sandbox Target User authorization. Then add Sandbox Client Key/Secret directly to Vercel as the sandbox variables above, set `TIKTOK_OAUTH_MODE=sandbox`, redeploy, and verify `/api/tiktok/diagnostic` before retrying OAuth.

## YouTube

Official Google/YouTube OAuth web-server flow reviewed against current Google documentation on 2026-08-30.

- Web server OAuth requires an exact authorized redirect URI and HTTPS.
- Use `state` protection, server-side code exchange, and `access_type=offline` when a refresh token is needed.
- Exact configured redirect URI for Cygnus: `https://investmentsespana.space/api/youtube/oauth/callback`.
- Current ContentFlow runtime reads `YOUTUBE_CLIENT_ID` and `YOUTUBE_CLIENT_SECRET`.
- Safe diagnostic: `/api/youtube/diagnostic` exposes only configuration booleans/lengths and redirect URI.

### Scope correction

Google's current YouTube Data API scope reference states:

- `youtube.upload`: manage/upload YouTube videos.
- `youtube`: manage the YouTube account.
- `youtube.force-ssl`: see, edit, and permanently delete YouTube videos, ratings, comments, and captions.

Therefore, if the intended operating contract includes permanent video deletion, `youtube.force-ssl` is the scope whose description explicitly covers permanent deletion. The user should not rely on `youtube.upload` alone for deletion.

### Next human step

1. Fix the Vercel runtime-variable visibility issue until `/api/youtube/diagnostic` reports both client credentials configured.
2. If permanent deletion is required, add `youtube.force-ssl` to the Google OAuth consent configuration before final OAuth certification.
3. Run the OAuth flow once, verify the exact authorized channel returned by `channels.list?mine=true`, verify granted scopes, and only then persist a server-side refresh token.

## Guardrails

- No permanent deletion is executed during integration/certification.
- No publication is executed during integration/certification.
- No secret or token is displayed in diagnostics or committed to GitHub.
- No duplicate social account/app is created unless a fresh inventory proves none exists.
- A browser session is not considered durable control; durable control is only certified after official OAuth/API verification of the exact asset.
