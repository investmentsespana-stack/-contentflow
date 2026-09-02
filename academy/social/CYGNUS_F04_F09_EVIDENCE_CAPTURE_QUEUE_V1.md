# Cygnus Academy AI — Evidence Capture Queue F04–F09 V1

Status: EXECUTABLE_EVIDENCE_QUEUE / NO_PUBLICATION
Date: 2026-09-02
Owner: Social Ops — Cygnus

Purpose: name one authentic core proof asset per content ID before premium production. Generic stock may support pacing but may not serve as the central proof.

| ID | Core proof asset | Capture requirement | Sensitive-data rule | Acceptance test | Status |
|---|---|---|---|---|---|
| F04 | `F04_before_after_real_task_capture_v1` | Record one real recurring work task before and after AI-assisted restructuring. Capture actual start/end timestamps or an honest measured duration. | Use synthetic/redacted work data; no client names, emails, policy/account data, credentials or private financial information. | Same task objective is visible before/after; timing is measured, not invented; output quality remains understandable on mobile. | QUEUED |
| F05 | `F05_source_answer_qa_correction_capture_v1` | Show a real primary/authoritative source, AI answer, QA check, detected issue or verification step, and corrected/confirmed output. | Use public/non-sensitive source material. | Viewer can visually follow source -> answer -> QA -> correction/confirmation. | QUEUED |
| F06 | `F06_capability_routing_workflow_capture_v1` | Capture a real/canonical Cygnus workflow mapping Research -> Writing -> Image -> Voice/Video -> QA, including actual task handoffs or system states where available. | Hide tokens, secrets, internal credentials, personal data, raw provider keys and confidential prompts. | Workflow stages and handoffs are real, legible and aligned with spoken narration. | QUEUED |
| F07 | `F07_cygnus_learning_cycle_capture_v1` | Capture one Cygnus learning journey: demonstration -> practice -> evidence submission -> feedback/evaluation. | Use demo/test learner data unless explicit consent exists. | All four stages are visible and attributable to the same learning mission. | QUEUED |
| F08 | `F08_opc_process_analysis_capture_v1` | Capture one authentic OPC-style process diagnosis with steps, time/friction, repetition, human-judgment points and automation opportunity. | Redact company/client identity unless the example is owned/public; do not expose confidential operational data. | Evidence supports one specific business problem and one automation opportunity without fabricated ROI. | QUEUED |
| F09 | `F09_director_orchestrator_coordination_capture_v1` | Capture Director Orquestador assigning a task, worker execution, QA/RARA verification and final status/result. | Hide secrets, tokens, internal credentials and confidential payloads. | Assignment -> execution -> verification -> result are visible as a single coherent run. | QUEUED |

## Capture specifications

- Prefer native screen recording at 1440p/4K where possible; minimum source should remain readable after 1080x1920 crop/composition.
- Record at 30 fps minimum unless a deliberate higher frame rate is available.
- Capture clean cursor movement; avoid accidental notifications, passwords, MFA codes, browser autofill, private inboxes or unrelated tabs.
- For dashboards, record both a wide context shot and 2–3 close-up crops for mobile readability.
- Preserve original source files before editing; generate a SHA-256 manifest at final production stage.
- Never fabricate time savings, QA failures, workflow results, learner outcomes or system states.

## Priority order

1. F09 Director Orquestador evidence — existing system evidence is likely closest to production-ready.
2. F06 capability-routing workflow — can reuse canonical system architecture if the live state is authentic.
3. F05 verification loop — simple public-source example can be captured safely.
4. F08 OPC process diagnosis — use a sanitized owned/example process.
5. F07 Cygnus learning cycle — requires stable learner-flow screens.
6. F04 measurable before/after — requires honest timing capture and therefore should not be rushed.

## Gate

A content item moves `EDITORIAL_READY -> EVIDENCE_READY` only when its named proof asset exists, is readable, provenance is recorded, and no confidential/sensitive data is present.

No upload or publication is authorized by this queue.