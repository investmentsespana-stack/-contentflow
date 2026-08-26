# ContentFlow AI Blueprint Master v3

## 1. Verdicts
| Verdict | Decision | Rationale (Traceable to Artifacts) |
|---------|----------|-------------------------------------|
| **GO to controlled MVP build** | ✅ **GO** | No verified architecture contradictions exist. Pending RLS gap does not block initial blueprint planning per `academy_phase0_reuse_security_audit_v1`. |
| **GO/NO-GO for customer-facing reuse of existing internal assets** | ❌ **NO-GO** | Verified security finding confirms 6 internal tables have disabled RLS with no evidence of customer-facing security controls. Per same audit: "No verified data tables are approved for customer access." |
| **GO/NO-GO for commercial production** | ❌ **NO-GO** | Critical security gap of 6 RLS-disabled internal tables remains unremediated. No verified evidence of production-hardened security or compliance exists. |

## 2. Reuse Matrix & Architecture Boundary
**Source:** `academy_phase0_reuse_security_audit_v1` (Verified Reuse: 72%)

| Component | Layer | Reuse Status | Boundary |
|-----------|-------|--------------|----------|
| Director Core | Control Plane | ✅ As-Is | Multi-project coordinator via `project_key` |
| RARA Tool | Control Plane | ✅ As-Is | Separate repair/review workflow tool |
| Durable Control Plane Tooling | Control Plane | ✅ As-Is | Backlog, runs, review, evidence, canary, trace |
| 6 RLS-Disabled Tables | Internal | ❌ Do Not Reuse | **INVESTIGATE FIRST** - No classification without evidence |
| All Customer Data Plane Components | Customer Product | ❌ Build New | **EXPLICIT NO DATA** - No verified evidence exists |

**Architecture Boundary:**
- **Existing/Reused:** Director/RARA/durable control plane (verified).
- **NEW:** Complete customer data plane (unverified, must be built).

## 3. Target Customer Data Domains & Tenancy/Security Principles
**Source:** `academy_blueprint_security_tenancy_governance_v1`

**Domains (NEW - No Verified Evidence):**
- Learner Profiles & Progress
- Course Catalog & Enrollment
- Assessment Submissions & Grades
- Certification Records
- Community Content
- Professional Workspace Projects

**Tenancy Principles:**
- Control Plane: Multi-project via `project_key` (verified).
- Customer Data Plane: **Design Required** - No verified model exists.

**Security Principles & RLS Investigation:**
- **Rule:** No blind RLS changes.
- **6 RLS-Disabled Tables:** `contentflow_workflow_e2e_state`, `director_recovery_learning_memory`, `contentflow_capability_certifications`, `contentflow_primary_source_evidence`, `director_project_task_scope`, `contentflow_durable_task_stages`.
- **Required Pre-Remediation Steps (Per Audit):**
    1. Classify each table as **internal-only** or **candidate customer reuse**.
    2. Document all existing database grants and calling entities.
    3. Design tailored RLS policies aligned with classification.
    4. Test in isolated non-production environment.
    5. Approve only after successful testing.

## 4. Academy/Course Factory/Tutor/Professor/Specialist/Agent Academy Lifecycle
**Source:** `academy_blueprint_education_agents_v1` & `academy_blueprint_product_experience_v1`

**Lifecycle Separation:**
- **Academy Platform:** Learn → Certify → Specialize journey (Customer Data Plane - NEW).
- **Course Factory:** Research → Curriculum → Lessons → Exercises → Project → RARA → QA → Publish (Orchestrated by Director Core).
- **AI Tutor:** Interactive learning assistant (NEW).
- **Virtual Professors/Specialists:** Role-based expert avatars (NEW, non-Avatar Studio).
- **Agent Academy:** Train/certify teaching agents using verified content (Uses `contentflow_capability_certifications` table post-RLS-fix).

**Avatar Project Separation:** Explicitly excluded per `academy_blueprint_product_experience_v1`. No components depend on it.

## 5. Mandatory Business AI Transformation Audit 360
**Source:** `academy_blueprint_business_audit360_v1`

**Mandatory Pre-Automation Gate:** No company automation may bypass this audit.

**Required Evidence Schema:** External, Internal, Operational, Automation-Specific (tagged with `builder_run_id`).

**Scoring & Formulas:**
- **Automation Opportunity Score (AOS):** (Sum of 7 dimension scores)/7. Threshold: ≥7 to PILOT/AUTOMATE.
- **Technology Fit Score (TFS):** Leverages reuse audit. Threshold: ≥7 required for GO.
- **Financial Formulas (Variables - NO INVENTED DATA):**
    - `Current Annual Cost (CAC) = (Labor Cost_manual + Tool Cost_manual + Error Cost_manual)`
    - `Automation Investment (AI) = (Development Cost + Licensing Cost_new + Training Cost + Change Management Cost)`
    - `Annual Run Cost (ARC) = (Maintenance Cost + Licensing Cost_new + Labor Cost_residual + Error Cost_automated)`
    - `Annual Savings (AS) = CAC - ARC`
    - `Simple Payback Period (years) = AI / AS`
    - `ROI (%) = ((AS * 5) - AI) / AI * 100`

**Automation Classification:** AUTOMATE, PILOT, REDESIGN, KEEP HUMAN, DO NOT AUTOMATE.

**GO/NO-GO Gates:**
1. Evidence Completeness (≥95%)
2. AOS (≥1 candidate ≥7)
3. TFS (≥7)
4. Financial Viability (ROI positive within 3 years, Net Savings positive by Year 2)
5. Canary & Rollback Plan (Documented)

## 6. Cloud Lab + Graduate Builder Cloud
**Source:** `academy_blueprint_cloud_builder_economics_v1`

**Verified Control Plane Services (Reused):** Director Core, RARA Tool, Durable Control Plane Tooling.

**Customer-Facing Services (EXPLICIT NO DATA - Build New):** VPS/lab templates, provisioning lifecycle, backup, monitoring, cloud storage, AI/model credits, managed agents, custom workflows, deployment pipelines, graduate conversion pathways.

**Continued Professional Relationship:** Graduate retention path design required (unverified).

## 7. Agent Capability Layer vs. Dynamic Multi-Provider Model Router
**Source:** `academy_blueprint_model_agent_router_v1`

**Separation:**
- **Agent Layer:** Stable, provider-agnostic contracts tied to `director_project_task_scope`. Declares task requirements (complexity, quality, budget).
- **Model Router:** Dynamic selection via abstract interface. Uses live provider telemetry for cost/quality.

**Routing Decision Contract:** `task_id`, `agent_contract_id`, `selected_provider`, `selected_model`, `cost_estimate`, `quality_score`, `provider_health_status`.

**Low-Cost Model Eligibility (ALL must be met):**
1. Task = Low Complexity/Risk
2. Model quality score ≥ agent minimum threshold
3. Estimated cost ≤ per-task budget
4. Provider status = healthy

## 8. Unit Economics & Positive-Margin Rules
**Source:** `academy_blueprint_cloud_builder_economics_v1` (EXPLICIT NO DATA for prices)

**Formulas (NO DATA variables):**
- **Control Plane Margin:** `(Verified Operational Revenue) - (Verified Operational Costs)`
- **Customer Margin:** `(Total Customer Revenue) - (Variable Resource Costs + Fixed Operational Costs)`

**Positive-Margin Rules:**
1. Per-task budget limits enforced by Director Core.
2. Real-time cost tracking via durable control plane telemetry.
3. Hard stops prevent overspending allocated project budgets.
4. **Guardrail:** Variable-cost resources cannot be sold as unlimited. Explicit hard limits required.

## 9. Observability/Security/Risk Gates
**Observability:** Leverage durable control plane trace/evidence tooling (verified).
**Security Gates:**
1. **RLS Remediation Gate:** All 6 tables classified, policies designed/tested, approved.
2. **Customer Data Plane Security Gate:** All new tables have RLS enabled before production.
3. **Authentication Gate:** Implemented and scoped to control plane via `project_key`.
**Risk Gates:** Aligned with Business Audit 360 Gates (Evidence, AOS, TFS, Financial, Canary).

## 10. Complete Implementation Epics
**Epic 1: Security Foundation & RLS Investigation**
- **Dependencies:** None.
- **Tasks:** Classify 6 RLS-disabled tables; document grants/callers; design/test RLS policies.
- **Acceptance Gate:** RLS Remediation Gate passed.

**Epic 2: Customer Data Plane Schema Design**
- **Dependencies:** Epic 1 (classification informs boundaries).
- **Tasks:** Design learner, course, assessment, certification, community, workspace tables with RLS.
- **Acceptance Gate:** All new tables have RLS policies defined.

**Epic 3: Academy Platform MVP (Learn + Certify)**
- **Dependencies:** Epic 2.
- **Tasks:** Build course catalog, enrollment, AI Tutor (basic), assessment engine, certification issuance.
- **Acceptance Gate:** End-to-end learner journey works; certifications stored securely.

**Epic 4: Course Factory & Agent Integration**
- **Dependencies:** Epic 1 (RLS-fixed tables), Epic 3.
- **Tasks:** Configure Director Core for education workflows; integrate RARA for content QA; implement Agent Academy training pipeline.
- **Acceptance Gate:** Course production pipeline operational; agents can be trained/certified.

**Epic 5: Professional Workspace (Build + Deploy Sandbox)**
- **Dependencies:** Epic 2, Epic 3 (Graduate transition).
- **Tasks:** Build VPS/lab provisioning; deployment pipelines; graduate access control.
- **Acceptance Gate:** Graduates can provision resources and deploy projects.

**Epic 6: Model Router & Economics Integration**
- **Dependencies:** Epic 4.
- **Tasks:** Implement provider abstraction layer; cost-aware routing; budget guardrails.
- **Acceptance Gate:** Router selects models based on cost/quality/budget; positive margin enforced.

**Epic 7: Business Audit 360 Integration**
- **Dependencies:** All epics for automation candidates.
- **Tasks:** Implement evidence collection; scoring framework; GO/NO-GO gate enforcement.
- **Acceptance Gate:** No automation bypasses audit; all gates enforceable.

## 11. First MVP Vertical & First Postgraduate Pilot
**MVP Vertical:** Academy Platform (Learn + Certify) + Course Factory.
- **Scope:** "Artificial Intelligence from Zero for Business" pilot course (8 weeks).
- **Components:** Course catalog, AI Tutor, assessments, certification, Director Core orchestration, RARA QA.
- **Postgraduate Pilot:** First graduates gain access to Professional Workspace (Build/Deploy sandbox).

## 12. Immediate Next Execution Wave
1. Initiate **Epic 1: Security Foundation** – Start investigation of 6 RLS-disabled tables.
2. Collect evidence for **Business Audit 360** on the Academy Platform automation candidate.
3. Draft design for **Customer Data Plane Schema** (Epic 2) based on product experience blueprint.
4. Configure **Director Core** with a dedicated education `project_key`.
5. Define **unit economics variables** for pilot costing (Labor Cost_manual, Development Cost, etc.).

**EVIDENCE CORRELATION:** All claims traceable to certified artifacts. No invented prices, runtime data, or deployment states.
