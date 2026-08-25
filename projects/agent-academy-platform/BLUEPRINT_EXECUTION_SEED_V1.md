# Agent Academy & Professional Cloud — Blueprint Execution Seed v1

Project key: `agent-academy-platform-v1`
Execution scope: Phase 0–1 only.

## Seeded Director tasks

1. `academy_phase0_reuse_security_audit_v1` — READY — priority 100
   - current ContentFlow reuse matrix;
   - current-state security blockers;
   - explicit unsafe reuse;
   - planning only.

2. `academy_blueprint_product_experience_v1` — PLANNED — depends on Phase 0
   - academy/product/user journeys;
   - graduate-to-professional lifecycle;
   - Avatar project boundary.

3. `academy_blueprint_education_agents_v1` — PLANNED — depends on Phase 0
   - course factory;
   - tutor/professors/specialists;
   - Agent Academy;
   - living-course/version/QA model.

4. `academy_blueprint_business_audit360_v1` — PLANNED — depends on Phase 0
   - mandatory external + internal + financial + operational Audit 360;
   - ROI/payback/risk;
   - baseline/canary/measurement;
   - human-only and do-not-automate classifications.

5. `academy_blueprint_cloud_builder_economics_v1` — PLANNED — depends on Phase 0
   - Cloud Lab;
   - Builder Cloud;
   - VPS/agents/model credits/services;
   - unit economics and margin protection.

6. `academy_blueprint_security_tenancy_governance_v1` — PLANNED — depends on Phase 0
   - tenancy/Auth/RLS/secrets/action permissions;
   - customer vs internal control-plane boundaries;
   - safe disposition of known RLS-disabled internal tables.

7. `academy_blueprint_model_agent_router_v1` — PLANNED — depends on Phase 0
   - agent contract vs model separation;
   - cost-aware multi-provider routing;
   - quality/fallback/quarantine/budget rules.

8. `academy_blueprint_master_v1` — PLANNED — depends on tasks 2–7
   - resolve contradictions;
   - produce Blueprint Master v1;
   - prioritized executable roadmap;
   - final GO/NO-GO for MVP construction.

## Current live evidence used to seed Phase 0

- Existing Director Core is the single authoritative coordinator.
- RARA is a separate repair/review service and not a second scheduler.
- Durable backlog, builder runs, review queue, evidence pipeline, canary controls and trace/ledger infrastructure are present.
- GitHub source repository: `investmentsespana-stack/-contentflow`.
- Supabase project: `koqpyfvnprmirqviafzq`.
- The current auto-loop discovers project keys from backlog and executes the durable Director Core cycle; the planning project therefore does not need a new scheduler.
- Known security gate at seed time: RLS disabled on six internal tables:
  - `contentflow_workflow_e2e_state`
  - `director_recovery_learning_memory`
  - `contentflow_capability_certifications`
  - `contentflow_primary_source_evidence`
  - `director_project_task_scope`
  - `contentflow_durable_task_stages`

Do not enable RLS blindly. The Blueprint Security task must first establish verified access requirements/policies and runtime tests.

## Execution guardrail

This seed authorizes architecture/research/planning artifacts only.

It does NOT authorize:
- broad feature implementation;
- customer-facing schema rollout;
- provider purchases;
- VPS purchases;
- production marketplace launch;
- modification/merger of the independent Avatar project.

## Promotion gate

MVP construction may begin only after `academy_blueprint_master_v1` completes and independent QA/Verifier review returns GO with no unresolved critical architecture/security contradiction.
