# YouTube OAuth — connected certification

Date: 2026-08-30

Status: OAUTH CONNECTED / CHANNEL VERIFIED / REFRESH TOKEN RECEIVED

Production callback returned schema `nexo.youtube.oauth.connection.v1` with status `connected_demo_session`.

Verified channel title: `ruben espana`.

Granted scopes:
- `https://www.googleapis.com/auth/youtube`
- `https://www.googleapis.com/auth/youtube.upload`

Refresh token received: true.

Security evidence:
- No Google/YouTube access token or refresh token was displayed in the callback page.
- Only a token fingerprint was exposed as non-secret diagnostic evidence.
- OAuth code exchange succeeded after replacing the invalid client credential pair with the newly created Google OAuth web client `Cygnus Academy AI-ContentFlow` and updating the Vercel Production variables.

Current certification boundary:
- OAuth authorization and exact YouTube channel discovery are certified.
- Current callback status is `connected_demo_session`; durable server-side encrypted refresh-token persistence must be completed/certified before claiming unattended durable automation.
- No permanent-delete capability is certified or authorized by this handoff.

Do not repeat Google OAuth client creation unless a future verified credential failure requires it.
