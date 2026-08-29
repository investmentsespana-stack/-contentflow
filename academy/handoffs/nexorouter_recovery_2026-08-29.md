# NexoRouter recovery — 2026-08-29

## Provider response
NexoRouter confirmed by email that the account balance was not the issue and that there was no billing hold on the API key. They reported an internal state had expired, causing 404 / `billing configuration is being validated` across many routes, and stated that the active catalog had been restored. They requested model id + request id only for models that continued failing.

## Live verification after provider response
Academy telemetry shows successful HTTP 200 executions through the normal NexoRouter builder path after the provider response:
- 2026-08-29 15:01:02 UTC — `Qwen/Qwen3-Max` — production — task `academy_stories_highlights_assets_v1` — HTTP 200 — primary route — catalog_validated=true.
- 2026-08-29 15:01:05 UTC — `Qwen/Qwen3-Max` — QA — same task — HTTP 200.
- 2026-08-29 15:01:08 UTC — `deepseek-ai/DeepSeek-V3.2-Exp` — production — task `academy_f02_f10_visual_production_v1` — HTTP 200.
- 2026-08-29 15:01:12 UTC — `deepseek-ai/DeepSeek-V3.2-Exp` — QA — same task — HTTP 200.
- 2026-08-29 15:01:39 UTC — `doubao-seed-2-0-mini-260215` — production — task `academy_reels_shorts_production_pack_v1` — HTTP 200.
- 2026-08-29 15:01:42 UTC — `Qwen/Qwen3-Max` — production — task `academy_linkedin_x_adaptation_pack_v1` — HTTP 200.
- 2026-08-29 15:01:45 UTC — `Qwen/Qwen3-Max` — QA — same task — HTTP 200.
- 2026-08-29 15:01:52 UTC — `doubao-seed-2-0-mini-260215` — QA — task `academy_reels_shorts_production_pack_v1` — HTTP 200.
- 2026-08-29 15:11:35 UTC — `deepseek-ai/DeepSeek-V3.2-Exp` — production — task `academy_f02_f10_visual_qa_v1` — HTTP 200.
- 2026-08-29 15:11:40 UTC — `deepseek-ai/DeepSeek-V3.2-Exp` — QA — same task — HTTP 200.

All observed entries used runner `v3_catalog_execution_probe_semantic_failover`, route `primary`, and `catalog_validated=true`.

## Conclusion
NexoRouter is operational again for the currently exercised Academy production/QA paths. The former blocker `EXTERNAL_PROVIDER_NEXOROUTER_BILLING_VALIDATION` is stale and must not continue blocking Academy work once this evidence is consumed.

## Director action
- Reconcile `academy_web_launch_qa_seo_v3`: clear the stale Nexo billing-validation blocker and return it to eligible execution, subject to its other real dependencies/gates.
- Do not send a support escalation for the models above because they are currently succeeding.
- If any of the models named by NexoRouter (Qwen3-Max, DeepSeek-V3.2, MiniMax-M3, GPT-4o, Kimi, Qwen 3.7) fails again with the same provider error, persist exact model id + provider/request correlation id and reply to the existing NexoRouter support thread with only the failing cases.
- Continue normal failover and catalog validation; do not pin to a model that is absent from the live catalog.
