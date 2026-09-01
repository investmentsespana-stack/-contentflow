# Notification & Escalation Service v1

**Task key:** `notification_escalation_service_v1`  
**Priority:** Critical / 100  
**Scope:** Global — all projects managed by the ContentFlow/Cygnus Director control plane.

## Objective
Ensure operational failures do not depend on the owner manually asking for intervention.

Canonical chain:

`Director -> RARA -> director_help_alerts -> expert/ChatGPT fallback -> corrective action -> verification -> learning`

## Runtime-grounded architecture
The implementation MUST reuse existing canonical control-plane primitives rather than inventing replacements:

- `contentflow_escalate_unresolved_incidents(project_key)` for exhausted autonomous-repair escalation.
- `director_repair_incidents` as the canonical repair-incident source.
- `director_help_alerts` as the canonical unresolved-help queue.
- existing Director cycle and RARA functions for first-line and second-line recovery.

Absence of optional notification credentials MUST NOT disable internal escalation.

## Required behavior

### 1. Watchdog
Observe canonical project/task state and detect stalled, blocked, failed, circuit-open, verification-stuck and repair-exhausted states. Time/attempt thresholds must be configurable. Repeated identical no-op attempts must not reset escalation age.

### 2. Director recovery
Director owns first-line recovery and persists evidence of each attempt.

### 3. RARA repair
After Director budget is exhausted, RARA performs root-cause repair and persists repair evidence. Status-only mutations are prohibited.

### 4. Unresolved-help escalation
After RARA/Director budget exhaustion, call/reuse `contentflow_escalate_unresolved_incidents()` and create/deduplicate an entry in `director_help_alerts`.

This internal escalation path is mandatory and MUST work independently of SMTP/OpenAI credentials.

### 5. Expert/ChatGPT fallback
A structured packet must contain project, task, age, attempts, errors, Director actions, RARA actions and evidence references.

If a direct approved OpenAI runtime bridge exists, it may be used. If it does not exist, the packet remains in the canonical help queue and the external ChatGPT escalation monitor is the fallback. Missing direct OpenAI credentials is therefore a degraded channel state, NOT a blocker for the core service.

### 6. Institutional email
PrivateEmail/SMTP is an additional delivery channel for critical alerts and daily/weekly summaries. Credentials and provider configuration must be stored in approved environment/vault configuration.

If SMTP is not configured, persist `EMAIL_CONFIGURATION_REQUIRED` for that channel and continue internal escalation. Never mark the whole escalation service BLOCKED solely because email is unavailable.

### 7. Idempotency and audit
Every escalation/notification uses a stable incident/event key. Do not duplicate alerts for an unchanged incident. Persist attempts, last error, next retry, delivery state, final resolution and verification evidence. Secrets must be redacted.

### 8. Reports
Daily: completed/running/blocked/failed, new/recovered incidents, help escalations, human-required actions and material runtime warnings.

Weekly: recurring root causes, MTTR, repair success by tier, repeated incidents suitable for learned automation, and unresolved aging.

## State model
`DETECTED -> DIRECTOR_RECOVERY -> RARA_REPAIR -> HELP_ESCALATED -> EXPERT_FALLBACK -> ACTION_EXECUTION -> VERIFYING -> RESOLVED`

Channel/degraded states:
`HUMAN_APPROVAL_REQUIRED`, `EMAIL_CONFIGURATION_REQUIRED`, `DIRECT_EXPERT_BRIDGE_UNAVAILABLE`, `NOTIFICATION_RETRY`, `CIRCUIT_OPEN`.

## Acceptance criteria
1. Existing `contentflow_escalate_unresolved_incidents()` is used or wrapped, not duplicated.
2. An exhausted Director/RARA canary produces a persisted `director_help_alerts` record automatically.
3. Internal escalation succeeds even when SMTP and direct OpenAI credentials are absent.
4. Missing SMTP produces `EMAIL_CONFIGURATION_REQUIRED` without blocking the core escalation state machine.
5. A structured expert packet is persisted for every unresolved escalation.
6. The external ChatGPT escalation fallback can consume unresolved help state and intervene without owner prompting.
7. Guardrails prevent destructive/financial/security/public-identity actions without approval.
8. Retry/dedup behavior is deterministic and bounded.
9. Daily and weekly summaries can be generated from canonical data.
10. `RESOLVED` requires post-repair verification and learning evidence.

## Completion gate
`runtime_proven` for the core escalation path. Email and direct expert API channels may be explicitly `CONFIGURATION_REQUIRED` without blocking core completion, provided their degraded state is persisted and visible.
