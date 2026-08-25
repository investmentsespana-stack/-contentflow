# Agent Academy & Professional Cloud — Master Project Contract v1

Status: PLANNING / BLUEPRINT GATE
Project key: `agent-academy-platform-v1`
Owner intent: build an education-to-professional AI ecosystem operated by the existing ContentFlow Director Core.

## 1. Mission

Build a platform that accompanies a user through the full lifecycle:

`learn -> certify -> specialize -> build -> deploy -> operate -> scale`

The platform is not only an academy. It must combine education, agent-assisted work, post-graduation professional infrastructure and recurring commercial services.

Core business principle: the graduate should remain connected to the ecosystem and be able to buy/use managed agents, AI consumption, VPS/cloud infrastructure, workflows, storage, backups, deployment, monitoring and support.

## 2. Non-negotiable architecture rule

Do NOT create a second orchestrator.

Reuse the existing ContentFlow Director Core as the single authoritative coordinator. RARA remains an independent repair/review capability and must not become a parallel scheduler. Existing durable state, evidence gating, review queues, concurrency controls and runtime ledgers should be reused wherever technically valid.

User-facing complexity must remain low. The user states intent; the system routes to the appropriate agents/models/tools.

## 3. Product domains

### 3.1 Academy

Required capabilities:
- courses, modules, lessons, video/text/resources;
- exercises, quizzes, projects and certificates;
- progress tracking and recommendations;
- AI tutor with course/lesson/student context;
- virtual professor characters;
- specialist instructors;
- community;
- course generation and maintenance pipeline;
- courses on demand by specialist agent/topic/level/industry.

### 3.2 Professor model

Initial cast should remain deliberately small (about 3–5 characters):
- Principal Professor: general orientation and continuity;
- Creative Specialist: prompting, image, video and content;
- Technical Specialist: APIs, n8n, automation, agents and infrastructure;
- Business Specialist: operations, monetization, ROI and transformation.

Maintain a balanced mix of male and female characters.

### 3.3 Avatar boundary

Do NOT build an Avatar Studio here.

The Real-Time Human AI Avatar project remains independent. This platform may consume characters or technology produced by that project when approved, but must not alter that project’s mission or absorb its scope.

### 3.4 AI Tutor

The tutor must know, subject to privacy/authorization:
- student identity/profile;
- active course/module/lesson;
- progress;
- completed exercises;
- prior errors and weak areas.

It should explain, simplify, generate examples/exercises, evaluate understanding and recommend next steps.

### 3.5 Agent Academy / Learn from an Agent

Users may choose an agent/specialist and request a learning path or course.

Example:
`Technical Agent -> n8n -> beginner -> real estate -> automate lead handling`

Before creating new content, the system must search for reusable existing courses/modules and avoid unnecessary duplication.

### 3.6 Living courses

Courses must be versioned and maintainable. Monitoring should detect relevant changes in APIs/tools/models and identify affected lessons. Updates require source evidence, RARA/Verifier review and QA before publication.

## 4. Course creation pipeline

Canonical flow:

`need -> research -> curriculum -> modules -> lessons -> examples -> exercises -> project -> evaluation -> RARA -> QA -> verifier -> certification -> publish`

No unverified course publication.

Research must prioritize primary sources. Unknown facts must be marked `NO DATA` or `UNVERIFIED`; never fabricate evidence.

## 5. Premium postgraduate program

Working title:

**Postgraduate Program in Orchestrator Director Architecture & Multi-Agent Systems**

Outcome: graduates must be able to analyze a business, design a multi-agent operating model, build an Orchestrator Director system, deploy it, measure it and demonstrate operational/financial value.

Minimum curriculum areas:
1. multi-agent architecture;
2. Director design;
3. agent contracts;
4. planning/routing/dependencies;
5. memory;
6. tools;
7. model routing;
8. RARA/root-cause recovery;
9. QA and Verifier;
10. durable workflows/ContentFlow patterns;
11. databases;
12. VPS/cloud;
13. observability;
14. security/governance;
15. cost control;
16. Business AI Transformation Audit 360;
17. automation economics/ROI;
18. canary/rollback/scaling;
19. productization;
20. commercialization.

Capstone: perform an evidence-based 360 audit on a real or complete simulated business, prioritize automation by ROI/risk, design/build a Director + agent system, run a canary and document measured results.

## 6. Mandatory Business AI Transformation Audit 360

No company automation may enter implementation without this audit.

### 6.1 External audit
Assess with traceable evidence:
- web presence and offer;
- products/services/pricing;
- copy/positioning;
- advertising;
- search/maps/reputation/reviews;
- competitors;
- customer journey and forms;
- response experience;
- social presence.

### 6.2 Internal audit
Assess:
- lead capture and sales;
- scheduling;
- service delivery/operations;
- billing/collections;
- follow-up/post-sale;
- accounting/admin/HR where relevant;
- communications;
- software/tools/data;
- manual work;
- human dependencies;
- failure modes.

### 6.3 Financial audit
Use declared/verifiable data only:
- revenue/cost/margins;
- labor and administrative costs;
- technology costs;
- error/rework cost;
- cost per customer/process;
- ticket/CAC/LTV/churn only when data exists;
- capacity constraints and lost opportunity.

### 6.4 Operational audit
Measure where data exists:
- process cycle time;
- queues/waiting;
- bottlenecks;
- rework/duplication;
- exceptions;
- dependencies/single points of failure;
- capacity/productivity;
- SLA/error rates.

### 6.5 Cross-check external vs internal
Detect costly contradictions, e.g. a public promise of immediate response against an internal two-hour response process.

### 6.6 Technology inventory
Inventory stack, APIs, CRM/ERP, databases, communications, servers, security, backups, costs, dependencies and risks.

Keep `digital maturity` separate from `technology maturity`.

### 6.7 Automation opportunity matrix
Score each process on:
- economic impact;
- operational impact;
- recoverable hours;
- revenue potential;
- technical difficulty;
- data quality;
- security/compliance risk;
- human judgment requirement;
- AI/infrastructure cost;
- expected ROI.

Classification:
- AUTOMATE NOW;
- PILOT;
- REDESIGN FIRST;
- KEEP HUMAN;
- DO NOT AUTOMATE YET.

### 6.8 Financial decision gate
For each candidate automation quantify, when evidence permits:
- initial investment;
- recurring operations cost;
- AI/model cost;
- infrastructure cost;
- expected savings;
- expected incremental revenue;
- payback;
- ROI;
- risk/scenarios.

No invented financial values. Missing inputs remain explicit variables.

### 6.9 Baseline / canary / measurement
Before automation, persist baseline KPIs.
Then:
`sandbox -> tests -> canary -> measured comparison -> GO/NO-GO -> scale`

Scale only if measurable operational/financial improvement is demonstrated and safety gates pass.

## 7. Cloud Lab for students

Provide course-linked labs and optional VPS service.

Suggested templates:
- n8n;
- Python;
- Node.js;
- Docker;
- PostgreSQL;
- Redis;
- API server;
- agent server;
- web development.

Example UX: `Create my n8n lab` provisions an isolated environment, applies baseline security, verifies health and connects it to the course.

## 8. Graduate Builder Cloud

Graduation begins a professional relationship rather than ending it.

Graduates should be able to subscribe to/use:
- VPS/cloud environments;
- agents;
- model/AI credits;
- databases/storage;
- backups;
- workflows;
- deployment;
- monitoring;
- support;
- managed operations.

The platform should help professionals optimize cost and productivity using verified recommendations.

## 9. Agent commercial layer

Professional users may assemble a team of capabilities such as:
- Research Agent;
- Coding Agent;
- Marketing Agent;
- Business Agent;
- Automation Agent;
- Support Agent.

Do not equate an agent with one fixed model. Agent identity/contracts are our software layer; model selection is dynamic.

## 10. Economic model router

Canonical rule:
- simple task -> low-cost qualified model;
- medium task -> efficient capable model;
- complex task -> advanced model;
- critical task -> advanced model + independent QA/evidence.

Optimize for value per dollar across quality, price, latency, reliability and fallback availability.

Avoid hard dependency on one provider. Support multi-provider routing and fallback.

## 11. Commercial profitability rules

The platform must be designed to earn recurring margin from:
- agents;
- AI/model/token consumption;
- VPS/infrastructure;
- managed services;
- support;
- automations;
- storage/backups;
- workflows/premium products;
- future marketplace commissions.

No commercial service may launch without measurable unit economics:
`provider cost + infrastructure + operations/support + risk allowance + target margin = customer price`

Never sell uncontrolled variable-cost resources as unlimited. Use plans, credits, quotas, limits, overages and alerts.

The customer buys outcomes/capability, not raw tokens or server complexity.

## 12. Community and future marketplace

Community should serve students, graduates, professionals and architects.

Prepare future marketplace contracts for approved:
- agents;
- workflows;
- courses;
- templates;
- automation components.

Marketplace launch is NOT MVP scope.

## 13. Security and governance

Required design areas:
- authentication/authorization;
- tenant/user isolation;
- RLS and least privilege;
- secret management;
- rate limiting/abuse controls;
- audit logging;
- backup/restore;
- rollback;
- privacy and data retention;
- tool/action authorization;
- controlled autonomy;
- evidence traceability.

Security-critical tables/functions may not be exposed by default.

Known current infrastructure gate: audit existing ContentFlow tables with RLS disabled before reusing them for customer-facing/student data. Do not blindly enable RLS without verified policies and runtime tests.

## 14. Observability and KPIs

Track at minimum:
- task/agent/model usage;
- tokens/cost/latency/retries;
- QA/rework/failures;
- uptime;
- educational activation/progress/completion;
- tutor usage/outcomes;
- graduate conversion to Builder Cloud;
- MRR/ARPU/churn/gross margin;
- agents/VPS active;
- automation hours/cost/error reduction;
- ROI and autonomy.

## 15. Reuse-first requirement

Before building any new subsystem, audit existing ContentFlow components and classify each as:
- reusable as-is;
- reusable with extension;
- repair first;
- replace;
- do not reuse.

Candidate assets to evaluate include:
- Director Core;
- RARA;
- durable task/backlog state;
- review/evidence queues;
- canary controls;
- model routing/Nexo integration;
- runtime ledgers/trace spans;
- Supabase;
- Vercel;
- GitHub/CI;
- existing observability.

## 16. Phased execution

### Phase 0 — architecture/reuse audit
No broad implementation. Produce evidence-backed reuse matrix and blockers.

### Phase 1 — Blueprint Master v1
Produce:
- component architecture;
- multi-agent architecture;
- product/UX architecture;
- data model proposal;
- API/boundary design;
- security model;
- course pipeline;
- Audit 360 pipeline;
- Cloud Lab/Builder Cloud architecture;
- unit economics framework;
- provider abstraction strategy;
- observability;
- risks;
- roadmap;
- GO/NO-GO gates.

### Phase 2 — MVP vertical
Prove one E2E vertical:
`user -> academy -> course -> tutor -> exercise -> cloud lab -> project -> QA -> certificate`

### Phase 3 — postgraduate pilot
Pilot the Audit 360 + Director design curriculum with controlled modules.

### Phase 4 — Builder Cloud
VPS, credits, model routing, agent subscriptions, billing, monitoring and managed services.

### Phase 5 — marketplace
Only after operational and unit-economic stability.

## 17. First course pilot

Working pilot:
**Artificial Intelligence from Zero for Business**

Use it to validate the course production pipeline, evidence discipline, QA and tutor integration before scaling the catalog.

## 18. First postgraduate pilot

Working module:
**Business AI Transformation Audit 360 & Multi-Agent System Design**

Must use a complete business case and teach evidence-first operational/financial diagnosis before automation design.

## 19. Definition of done for planning gate

Blueprint Gate is complete only when the Director produces and QA verifies:
1. reuse matrix with evidence;
2. target architecture and boundaries;
3. explicit non-goals;
4. epics/tasks/dependencies;
5. data model proposal;
6. security/tenant model;
7. course and audit pipelines;
8. Cloud/Builder service design;
9. unit economics model with unknowns explicit;
10. provider abstraction/routing strategy;
11. risk register;
12. MVP and canary plan;
13. measurable acceptance gates;
14. no unresolved critical architecture contradiction.

## 20. Prohibitions

Do not:
- copy third-party proprietary code/content/branding;
- automate a business without Audit 360;
- invent evidence or financial metrics;
- publish courses without QA/verification;
- deploy agents without explicit contracts/permissions;
- sell a service without unit economics;
- offer uncontrolled unlimited variable-cost usage;
- merge the independent Avatar project into this scope;
- create a second Director/orchestrator;
- create broad production customer tables before security/tenant design is approved;
- scale from sandbox directly to full production without canary evidence.

## 21. Immediate order to Director

Perform Phase 0 and Phase 1 only.

Return a **Blueprint Master v1** grounded in the current repository/runtime. Explicitly identify what is reusable, what is missing, what is unsafe to reuse and what must be built.

Every material recommendation must include: evidence/source, benefit, cost/complexity, risk, dependencies and acceptance criterion.

Do not start broad feature implementation until the Blueprint passes independent QA/Verifier review.
