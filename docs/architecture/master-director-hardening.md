# Master Director Hardening Plan

This document records the architecture improvements adopted from the external multi-agent benchmark and approved for ContentFlow implementation.

## Operating principles

1. **Hybrid control boundary** — use LLM reasoning for semantic planning, diagnosis, contextual routing and repair proposals; use deterministic code for state transitions, budgets, permissions, concurrency, dependency resolution, retries, rollback, acceptance gates and evidence verification.
2. **Durable event ledger and checkpoints** — every meaningful lifecycle transition must be correlated and recoverable. Recovery resumes from the last verified state and must not repeat committed successful work.
3. **Evidence-first completion** — no worker or judge assertion alone can mark a task complete. Acceptance criteria must map to reproducible artifacts, tests, runtime evidence, verified dependency evidence or explicitly allowed non-runtime proof.
4. **End-to-end traceability** — task → plan/dependencies → assignment → worker → reviewer/judge → tools/runtime → quality/cost → evidence → outcome → recovery/error fingerprint.
5. **Guardrails at every boundary** — input, tool/action, output/review and deploy/completion. Missing authorization or evidence fails closed.
6. **GitHub as source of truth** — versioned code and reproducible configuration are maintained in GitHub; secrets are never committed; production-impacting code should pass CI/evidence gates before deployment.
7. **Master Director / Project Adapter split** — reusable orchestration core remains independent from ContentFlow-specific tools, policies, budgets, schemas, acceptance criteria and worker requirements.
8. **Autonomy is measured** — utilization, effective completion, autonomous recovery, recurrence, evidence coverage, cost per accepted task and lead time determine autonomy claims.

## Implementation backlog

- `arch_runtime_atomic_claims`
- `arch_event_ledger_trace`
- `arch_guardrails_boundaries`
- `arch_evidence_ci_gate`
- `arch_autonomy_kpi_enforcement`
- `arch_master_project_adapter`

These tasks are intentionally separate from the previously approved ContentFlow completion directives. They harden the Director architecture while the existing build/QA work continues.
