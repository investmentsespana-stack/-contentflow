# CYGNUS CLIPPER SYSTEM v1

Status: ACTIVE BUILD
Owner: Cygnus Academy AI
Publication gate: CLOSED during pilot unless QA PASS + owner approval
Pilot size: 30 clips

## 1. Objective
Convert Cygnus long-form content — classes, interviews, demonstrations, podcasts and streams — into high-potential vertical clips for TikTok, Instagram Reels, YouTube Shorts and Facebook. Success is measured by attention plus downstream student/client acquisition and sales, not views alone.

## 2. Canonical pipeline
1. Source Intake — owned, licensed or explicitly authorized source only.
2. Hunter — identifies candidate segments and returns timestamps/transcript/context.
3. Scorer — scores hook, clarity, utility, emotion/curiosity, retention, shareability and CTA fit.
4. Clipper — produces 9:16 review MP4, removes dead air, reframes, subtitles and preserves provenance.
5. Copy — platform-specific title, caption, CTA and hashtags without changing source claims.
6. QA — fail-closed review for context, factual integrity, subtitles, edit quality and source rights.
7. Publisher Pack — prepares platform-specific packages. No automatic publication in the pilot.
8. Analytics — records supported metrics at 24 h, 72 h and 7 d.
9. Director — compares predicted potential with real outcomes and learns which topics/hooks/durations/styles to repeat.

## 3. Mandatory state contract
Every asset must carry: source_id, source_segment_id, rights_status, source_start_ms, source_end_ms, transcript_hash, edit_hash, clip_id, scorer_version, qa_state, publication_authorized, platform_variants, analytics_state and parent-child provenance.

`publication_authorized` defaults to `false` and may not become `true` during the pilot unless QA is PASS and owner approval is recorded.

## 4. Hunter output
Minimum fields: candidate_id, source_segment_id, start_ms, end_ms, transcript, context_summary, standalone_score_hint, selection_reason.

## 5. Scorer contract
Normalized criteria: hook, clarity, utility, emotion_curiosity, retention, shareability, cta_fit. Weights are versioned. AI predictions are hypotheses until measured against real platform outcomes.

## 6. Render contract
Pilot master: 1080x1920, 9:16, H.264/AAC, readable subtitles, source traceability, SHA-256 and `publication_authorized=false`.

## 7. QA contract
Reject if any of these fail: rights/provenance, self-contained meaning, claim integrity, subtitle readability, audio intelligibility, visual crop/safe zone, misleading edit, weak/unclear hook, or missing source evidence.

## 8. Analytics contract
Measurement windows: 24 h, 72 h, 7 d. Supported metrics when available: views, retention, watch time, percent viewed, shares, comments, saves, followers, clicks, leads, registrations and conversions. Missing platform metrics must be marked unavailable, never inferred.

## 9. Monetization funnel
Clip -> attention -> free content -> registration -> free Cygnus module -> paid course or service.
Secondary revenue candidates after evidence exists: platform monetization, affiliates, leads, digital products, AI services, clipping for third parties and sponsorships.

## 10. Pilot acceptance
The first 30 clips must each have complete provenance, Hunter candidate data, Scorer result, rendered review asset, platform copy, QA decision, publication state and analytics tracking identity. No clip is auto-published during V1.

## 11. Learning rule
Director learns from verified outcomes, not only AI predictions. It must preserve version history for scoring weights and decisions, and avoid calling a clip successful solely because it has views.

## 12. Commercialization gate
Clipping for third parties is unlocked only after Cygnus has a verified internal case study with reproducible metrics and traceable source-to-result evidence.
