# Director Handoff — YouTube / Social Ops — Cygnus Academy AI

Date: 2026-08-30
Priority: HIGH
Owner: Director / Social Ops
Channel target: existing YouTube channel `ruben espana`
Channel ID: `UCZhxLanR9eh7u2PtMv9Bxjg`

## Executive state

YouTube OAuth is already durably connected and certified. DO NOT repeat OAuth, create another channel, request credentials, or expose tokens.

Current public identity observed by certified inventory:
- Name: `ruben espana`
- Handle: `@rubenespana4255`
- Description: empty
- Legacy avatar: INVESTMENTS ESPAÑA
- Videos: 0
- Shorts: 0
- Playlists: 0
- Home sections: 0

Target identity: `Cygnus Academy AI`.

## Completed

1. Certified API inventory completed and stored as external evidence (`nexo.youtube.channel.inventory.v1`, Director evidence id 45, pass/verified).
2. Existing channel identity and stable channel ID verified.
3. No legacy videos/playlists exist, therefore classification is CONSERVAR=0 / ARCHIVAR-OCULTAR=0 / REVISAR=0. Permanent deletion remains prohibited.
4. Preferred handle prepared: `@CygnusAcademyAI`; alternative `@CygnusAcademyIA`. Public URL checks found no observable channel conflict, but final availability must be confirmed when saving in YouTube Studio.
5. Migration copy prepared, including institutional description and verified Facebook/Instagram targets. Web/landing link remains intentionally unset until verified.
6. Cygnus YouTube branding assets prepared and hashed:
   - avatar 800x800
   - banner 2560x1440
   - watermark 150x150
7. Initial channel organization prepared: Empieza aquí; Shorts | IA aplicada; IA aplicada al trabajo; Automatización y agentes; Auditoría 360; Clases y cursos; Profesores y avatares.
8. First controlled Short is prepared but remains `DRAFT_NOT_UPLOADED`. Upload and publication are separate human approval gates.
9. No video or Short was published. No permanent deletion occurred. No secret was exposed.

## Remaining work for Director to assign

### Lane A — Studio migration (requires authenticated YouTube Studio surface)
- Verify exact availability of `@CygnusAcademyAI` at save time.
- If available and no multichannel naming conflict exists, apply public name `Cygnus Academy AI` and preferred handle.
- Apply prepared avatar, banner and watermark.
- Apply verified institutional description and verified social links only.
- Perform visual QA after each reversible change.
- Capture evidence/receipt after every mutation.

Do NOT use `@CygnusAcademyIA` unless preferred handle is unavailable or Direction explicitly changes the global brand convention.

### Lane B — ContentFlow engineering (independent of Studio)
- Extend the durable YouTube adapter from inventory-only capability toward supported reversible channel-management operations where YouTube API permits them.
- Add preflight/dry-run and idempotency protection.
- Add before/after evidence capture and fail-closed channel-ID verification.
- Never implement permanent deletion as an implicit operation.

### Lane C — Editorial preproduction (independent)
- Prepare first approved channel trailer concept.
- Prepare playlist descriptions and ordering metadata.
- Keep first Short in draft; do not upload until explicit approval.
- Run RARA QA for claims, copyright/licensing, subtitles, legibility, audience, links and brand consistency.

### Lane D — Post-migration verification
- Re-run certified API inventory after Studio mutations.
- Confirm same Channel ID and new title.
- Visually verify handle, avatar, banner, description, links and watermark in Studio/public channel.
- Record BEFORE -> ACTION -> AFTER -> EVIDENCE -> BLOCKERS -> NEXT STEP.

## Director dispatch policy

Assign all independent Lane B and Lane C work immediately even if Lane A is blocked by unavailable Studio/browser surface. Do not idle workers because a UI dependency is blocked. Lane D begins as soon as Lane A has a verified mutation.

If dispatchable work reaches zero because only external Studio authorization remains, record EXTERNAL_DEPENDENCY rather than forcing retries.

## Guardrails

- Same existing channel only.
- No repeated OAuth.
- No duplicate channel.
- No token/credential exposure.
- No permanent deletion.
- No invented IDs or evidence.
- No video/Short publication without explicit approval.
- Handle change only after exact save-time availability verification.
- Continue independent work immediately on any blocker.

## Canonical references

- `academy/handoffs/SOCIAL_OAUTH_SHARED_STATUS_2026-08-30.md`
- `academy/handoffs/YOUTUBE_CYGNUS_MIGRATION_AUDIT_2026-08-30.md`
- `api/youtube/demo.js`
- `src/platform/youtube-channel-inventory.mjs`

Director: ingest this handoff as canonical current state and assign remaining independent tasks without repeating completed work.