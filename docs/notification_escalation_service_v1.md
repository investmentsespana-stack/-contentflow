# Notification & Escalation Service v1

**Task key:** `notification_escalation_service_v1`  
**Priority:** Critical / 100  
**Scope:** Global — applies to all projects managed by the ContentFlow/Cygnus Director control plane.

## Objective
Implement a durable notification and escalation service so operational failures do not depend on the owner manually asking for intervention.

Canonical escalation chain:

`Director -> RARA -> ChatGPT/OpenAI escalation bridge -> Director execution -> verification -> learning`.

The service must also send automated email alerts and daily/weekly operational summaries to a configured institutional recipient.

## Required capabilities

### 1. Task watchdog
- Observe active project/task state from canonical Director tables and runtime evidence.
- Detect stalled, blocked, failed, circuit-open, verification-stuck, and repeated-repair states.
- Use configurable time thresholds and attempt thresholds; do not hard-code project-specific values.
- Preserve project/task correlation IDs and evidence references.

### 2. Director escalation
- Director remains first-line owner.
- When a task crosses its threshold, Director must attempt the configured recovery action and persist the result.
- Repeated identical no-op attempts must not reset the escalation clock.

### 3. RARA repair
- After Director's recovery budget is exhausted, create a RARA repair incident with complete evidence.
- RARA must perform root-cause-oriented repair, not superficial status mutation.
- Persist repair attempt, changed artifact/configuration, evidence, outcome and next state.

### 4. Expert escalation bridge
If Director + RARA fail within the configured time/attempt budget:
- Build a structured escalation packet containing project, task, current state, elapsed time, attempts, errors, recent logs/evidence, Director actions and RARA actions.
- Send the packet through the approved OpenAI/ChatGPT integration available to the control plane.
- Never embed API keys, credentials or secrets in source code or payload logs.
- If no approved OpenAI runtime credential/bridge exists, enter `EXPERT_ESCALATION_CONFIGURATION_REQUIRED`, alert the owner, and preserve the packet for retry. Do not fake an expert response.
- Validate returned actions against existing authorization/tool-action guardrails before execution.
- Director executes approved corrective actions and immediately re-verifies.

### 5. Email notification service
Support institutional email delivery through the approved mail provider configuration (currently PrivateEmail is intended, but SMTP host/ports/auth must be verified from authoritative provider settings at implementation time).

Required alert classes:
- CRITICAL escalation to expert tier.
- Recovery succeeded after escalation.
- Recovery exhausted / human approval required.
- Daily operational summary.
- Weekly operational summary.

Configuration must be environment/vault based, e.g. recipient, SMTP credentials, sender identity and provider settings. No secrets in Git or database plaintext logs.

### 6. Idempotency, retries and deduplication
- Every notification/escalation gets a stable event/idempotency key.
- Retry only typed transient failures with bounded exponential backoff.
- Do not send duplicate critical alerts for the same unchanged incident.
- A materially changed state may generate a new notification event.
- Persist attempts, last error, next eligible retry time and final outcome.

### 7. Audit trail
Persist enough data to answer:
- what failed;
- when it started;
- how long Director had it;
- what Director tried;
- what RARA tried;
- whether/when expert escalation happened;
- which corrective actions were returned/executed;
- notification delivery state;
- verification evidence;
- final resolution and learned repair signature.

Secrets and sensitive payload fragments must be redacted.

### 8. Reporting
Daily summary should include per project:
- completed / running / blocked / failed;
- new incidents;
- recovered incidents;
- expert escalations;
- tasks requiring human approval;
- material cost/quality/runtime warnings when canonical telemetry exists.

Weekly summary should additionally include:
- recurring root causes;
- mean time to recovery;
- repair success rate by Director/RARA/expert tier;
- repeated incidents that should become permanent automation/learning rules;
- unresolved blockers and aging.

### 9. Global project behavior
This is control-plane infrastructure, not Academy-only. Project discovery must use the Director's canonical project registry/activity sources. New projects should inherit the service without requiring a new copy of the implementation.

## Guardrails
- No destructive action, billing action, public-identity change, credential rotation, or security-boundary weakening without the existing approval policy.
- Never mark a task recovered without runtime/evidence verification appropriate to its contract.
- No status-only repair that hides an unresolved runtime problem.
- No unofficial credential scraping or bypass of provider authorization.

## Suggested state model
`DETECTED -> DIRECTOR_RECOVERY -> RARA_REPAIR -> EXPERT_ESCALATION -> ACTION_EXECUTION -> VERIFYING -> RESOLVED`

Exceptional states:
`HUMAN_APPROVAL_REQUIRED`, `EXPERT_ESCALATION_CONFIGURATION_REQUIRED`, `NOTIFICATION_RETRY`, `CIRCUIT_OPEN`.

## Acceptance criteria
1. A deterministic canary task can be forced into a stalled state.
2. Director attempts recovery and evidence is persisted.
3. RARA is invoked after the configured Director threshold.
4. When RARA exhausts its threshold, an expert escalation packet is created automatically without owner prompting.
5. With approved OpenAI bridge credentials configured, the packet is sent and the response is captured; without them, the service fails safely with an explicit configuration state.
6. Returned actions cannot bypass authorization guardrails.
7. A critical email alert is delivered through the configured institutional mail channel and delivery evidence is persisted.
8. Transient mail/API failure retries are bounded and idempotent.
9. A daily and weekly report can be generated from persisted canonical data.
10. End-to-end canary reaches `RESOLVED` only after post-repair verification.
11. RARA/Director learning store records the final root cause and successful repair signature for future autonomous handling.

## Completion gate
`runtime_proven` with repository commit evidence, canary runtime evidence, notification-delivery evidence, expert-escalation evidence or explicit safe configuration blocker, and QA/Judge approval.