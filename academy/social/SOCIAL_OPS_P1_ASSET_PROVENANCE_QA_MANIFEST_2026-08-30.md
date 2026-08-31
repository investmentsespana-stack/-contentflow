# Cygnus Academy AI — P1 Asset Provenance + QA Manifest

Date: 2026-08-30
Status: PRODUCTION_PREP / NO_PUBLICATION

## Locked platform outputs

- Facebook: 1080x1350 static/carousel-ready.
- Instagram: 1080x1350 carousel; Reel adaptation reserved.
- TikTok: 1080x1920, 25–30 seconds.
- YouTube Shorts: 1080x1920, 30 seconds.

## Provenance requirements

Every final binary must record:
- source asset path
- creator/generator
- generation or acquisition date
- license/usage basis
- transformation history
- SHA-256
- target platforms

No final asset passes upload QA without a completed provenance row.

## Current verified reusable brand assets

| Asset | Repo path | Usage basis | State |
|---|---|---|---|
| YouTube avatar | academy/social/youtube/branding/cygnus_youtube_avatar_800x800.jpg | internally prepared Cygnus brand asset | VERIFIED_PRESENT |
| YouTube banner | academy/social/youtube/branding/cygnus_youtube_banner_2560x1440.jpg | internally prepared Cygnus brand asset | VERIFIED_PRESENT |
| YouTube watermark | academy/social/youtube/branding/cygnus_youtube_watermark_150x150.png | internally prepared Cygnus brand asset | VERIFIED_PRESENT |

## Pixel / safe-zone QA

Facebook / Instagram feed:
- exact canvas 1080x1350
- critical text at least 90 px from all edges
- no CTA or logo clipped by crop variants
- minimum readable body text at mobile display
- no unverified URLs

TikTok / YouTube Shorts:
- exact canvas 1080x1920
- keep critical text/logo inside center safe region
- reserve lower area for platform UI/captions
- burned captions synchronized and legible
- opening hook visible immediately
- end card <= 2.5 seconds and readable
- audio peak/clipping check before upload

## Subtitle QA

- transcription matches spoken script
- punctuation normalized
- no invented claims
- brand name exactly `Cygnus Academy AI`
- line lengths optimized for mobile
- subtitle timing does not cross scene boundaries unnecessarily
- separate SRT/VTT retained when platform supports it

## RARA decision

PASS now:
- approved concept/copy
- target dimensions
- brand naming
- sensitive-data guardrail
- no public upload

CONDITIONAL:
- final rendered binaries require checksum + provenance + visual safe-zone QA + subtitle/audio QA.

CLOSED:
- public publication
- mass autonomous publication
- permanent deletion
