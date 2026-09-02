# Cygnus Academy AI — Video Production Quality Standard V1

Status: CANONICAL_PRODUCTION_STANDARD
Date: 2026-09-02
Owner: Social Ops — Cygnus

## Purpose

Every Cygnus Reel/Short/video must look and sound like professional institutional content, not a quick template render. This standard applies immediately to F02–F10 and to all future social video batches.

The Deep Funnel/HIR editorial rule remains mandatory:

`1 content = 1 cluster + 1 intention + 1 problem + 1 result + 1 funnel stage`

Quality never overrides semantic coherence. A beautiful video with weak evidence or mixed intent must be rejected.

## Production principle

Use the best available execution path. The Nebius GPU VM may be used whenever it materially improves avatar quality, lipsync, denoise, enhancement, upscale, compositing, generation, motion work, rendering speed, or batch production. Do not consume GPU merely to satisfy a checkbox; use it when it creates measurable visual/audio/throughput benefit.

No publication is authorized by this standard.

## Visual quality gate

Minimum delivery for vertical social:
- 1080x1920 final output, 9:16.
- Clean high-resolution source material; avoid visibly compressed screenshots or low-resolution screen captures.
- 30 fps minimum unless a deliberate cinematic choice requires otherwise.
- H.264/H.265 delivery appropriate to target platform; retain a high-quality master before platform compression.
- No stretched/cropped UI, illegible dashboards, clipped text, aliasing, broken masks, obvious generation artifacts or accidental cursor clutter.
- Captions and key graphics remain inside safe areas and readable on a phone.
- Brand-consistent typography, spacing, hierarchy and motion.
- Professional cuts/transitions; no excessive effects that distract from the proof being shown.

When source quality permits, retain a higher-resolution production master before final 1080x1920 delivery.

## Audio quality gate

- Voice must be clean, intelligible and foregrounded.
- Remove distracting noise, hum, clipping, pops and abrupt level jumps.
- Music/SFX must support comprehension, never overpower narration.
- Maintain consistent perceived loudness across the batch and leave safe headroom to avoid platform clipping.
- Pronunciation of Cygnus, product names and technical terms must be checked before approval.

## Avatar / presenter quality

When an avatar/professor is used:
- natural eye behavior and facial motion;
- lipsync visually aligned with speech;
- no obvious mouth tearing, face warping, frozen expression or temporal flicker;
- professional wardrobe/background consistent with Cygnus identity;
- framing appropriate for mobile vertical video;
- no uncanny or distracting motion accepted merely because the render completed.

If the first avatar render does not meet this bar, RARA must reject and rerun/refine rather than accept a technically valid but visibly weak output.

## Evidence-first visual design

Each video must visibly prove the central claim whenever proof can be shown:
- real screen recording;
- real workflow;
- real document/process;
- real Cygnus/Skool environment;
- Director Orquestador execution;
- before/after comparison with honest measurement;
- QA/verification loop;
- learner artifact or real output.

Avoid generic stock visuals as the primary proof. B-roll may support pacing, but the core evidence must remain visible and understandable.

## Editing architecture

Default short-form rhythm:
- 0–3 s: premium visual hook + strong spoken/text hook.
- 3–10 s: problem with immediate visual context.
- 10–30 s: proof/demonstration, using punch-ins, callouts or screen focus where useful.
- 30–45 s: concise explanation.
- 45–55 s: verifiable result.
- final: one CTA aligned with the Deep Funnel stage.

For 20–35 s versions, preserve the same logic without rushing readability. Authority versions may extend to 60–120 s when evidence warrants it.

## Motion graphics and captions

- Captions are timed to speech, not dumped as paragraphs.
- Highlight only the most important semantic words; do not animate every word.
- Use Cygnus visual language consistently: dark navy foundation, cyan/blue for clarity/technology, violet for transformation, moderate magenta for action, emerald for progress, gold for achievement/premium.
- Motion should feel premium and restrained.
- Charts, process arrows and workflow maps must be readable at phone size.

## QA / RARA acceptance checklist

A video cannot become `READY_FOR_APPROVAL` unless all applicable checks pass:
1. Deep Funnel/HIR metadata complete.
2. One cluster/intention/problem/result/stage only.
3. Hook visible and understandable inside first 3 seconds.
4. Visual proof matches the spoken claim.
5. Screen recordings are sharp and readable.
6. Avatar/presenter passes naturalness and lipsync review when used.
7. No visible generation/compositing artifacts.
8. Voice intelligibility and consistent audio levels pass.
9. Captions are synchronized, spelled correctly and mobile-safe.
10. Brand graphics are consistent.
11. CTA matches exactly one next action.
12. No unsupported performance claims.
13. No confidential/sensitive data visible.
14. Final export passes playback inspection from beginning to end.
15. SHA-256/manifests and production evidence are recorded for final assets.
16. Upload/publication gate remains CLOSED until separately approved.

Any failed item returns the asset to production with status `RARA_REJECTED_QUALITY` or the relevant evidence/editorial blocker.

## F02–F10 production priority

Start with F02 and F03 as the first premium production pair because their editorial architecture is already complete. Produce them in parallel where dependencies permit.

For F04–F09, capture authentic evidence first, then produce to the same quality bar. F10 remains conversion-gated and must not be released before sufficient warm-up signals exist.

## GPU/VM decision rule

Use Nebius VM/GPU when at least one applies:
- avatar/lipsync generation or refinement;
- video generation/enhancement/upscale/denoise;
- GPU-accelerated compositing/rendering materially reduces time;
- batch rendering multiple platform variants;
- visual QA reveals artifacts that GPU-assisted refinement can repair.

CPU/local/API execution remains acceptable for scripting, metadata, captions, manifests, lightweight assembly and QA that does not benefit from GPU.

## Publication guardrail

Production approval is not publication approval.

Status sequence:
`EDITORIAL_READY -> EVIDENCE_READY -> PRODUCTION -> RARA_QA -> READY_FOR_DIRECTOR_APPROVAL -> [separate publication authorization]`

Organic strategy remains active. Paid campaigns and mass publication remain closed.