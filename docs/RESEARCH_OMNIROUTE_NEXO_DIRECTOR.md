# Research Scenario — OmniRoute vs Nexo for ContentFlow Director

Status: OPEN — research only, no production integration authorized yet.

## Objective
Determine whether OmniRoute should be incorporated into ContentFlow as a routing/resilience layer beneath the Director, alongside NexoRouter, without replacing the Director's project-level orchestration, learning, ranking, QA, or governance.

## Current ContentFlow principle
The Director remains the decision-maker for project decomposition, agent specialization, task assignment, QA, learning, ranking, retries, escalation and final synthesis. A routing layer may optimize transport/provider selection, but must not take over project governance.

## Working architecture under evaluation

User / Project
  -> ContentFlow Director
  -> Task classifier + planner
  -> Resource policy / agent ranking
  -> Routing abstraction layer
       -> NexoRouter
       -> OmniRoute (candidate)
       -> future approved providers
  -> Worker agents
  -> QA / Judge
  -> Metrics + memory
  -> Director learning loop

## Research questions
1. Can OmniRoute operate behind a stable OpenAI-compatible adapter without forcing changes throughout ContentFlow?
2. Can Nexo remain the primary resource pool while OmniRoute provides fallback, health-aware routing or selected secondary providers?
3. Which OmniRoute capabilities are worth adopting: health scoring, circuit breaker, retries, quota awareness, cost/latency routing, compression, fusion/pipeline, MCP/A2A, memory?
4. Which capabilities duplicate or conflict with Director responsibilities?
5. Does adding OmniRoute reduce failure rate and latency without reducing output quality or observability?
6. What are the security implications of local/VPS deployment, OAuth/API key storage, MITM features and provider terms?
7. What measurable cost savings are real under ContentFlow workloads, rather than vendor/project marketing claims?
8. How does OmniRoute behave under Nexo rate-limit, timeout, malformed response, provider outage and quota exhaustion scenarios?

## Comparison model
Evaluate Nexo-only baseline against Nexo + OmniRoute candidate stack on:
- task success rate
- p50/p95 latency
- retries per completed task
- worker timeout rate
- provider/model failover success
- cost per accepted task
- tokens per accepted task
- QA score / judge pass rate
- routing decision explainability
- operational complexity
- security surface
- recovery time after provider failure

## Ownership boundaries
### Director owns
- project understanding
- task decomposition
- specialization
- agent/model ranking from empirical ContentFlow history
- concurrency budget at project level
- QA and acceptance criteria
- error learning and memory
- re-planning
- escalation / HELP signal
- final synthesis

### Routing layer may own
- endpoint/provider health
- transport retries
- circuit breaking
- per-provider rate/quota awareness
- cost/latency-aware endpoint selection
- transparent provider fallback
- request telemetry
- optional token compression after quality validation

### Nexo role
Nexo remains a resource/provider gateway and model pool. It is not assumed to be replaced by OmniRoute.

## Integration phases
### Phase 0 — Research (now)
No production changes. Inspect OmniRoute architecture, license, routing algorithms, security model, deployment requirements and interfaces. Map overlap with ContentFlow.

Exit gate: written architecture decision record and test plan.

### Phase 1 — Isolated sandbox
Run OmniRoute outside production. Connect only disposable/test credentials and one non-critical provider path. Reproduce ContentFlow request shapes.

Exit gate: compatibility, security and observability verified.

### Phase 2 — Shadow benchmark
For the same benchmark tasks, keep Nexo-only as control and send duplicated non-production workloads through the candidate route. Do not allow the candidate path to affect production outputs.

Exit gate: statistically meaningful improvement in at least reliability or cost/latency with no unacceptable quality loss.

### Phase 3 — Limited fallback
Director still selects the worker class. OmniRoute is enabled only as a fallback/transport resilience layer for a small low-risk workload class.

Exit gate: failover works, no routing loops, cost budgets respected, logs sufficient for audit.

### Phase 4 — Policy routing
Enable selected health/cost/latency strategies where benchmark evidence shows benefit. Director keeps final resource policy and can pin or exclude providers.

Exit gate: measurable Director efficiency improvement and stable QA.

### Phase 5 — Optional advanced features
Only after validation, consider prompt compression, fusion, pipelines, MCP/A2A integration or external providers. Each feature requires its own A/B test and rollback switch.

## Non-negotiable safeguards
- No production secret copied into research documentation.
- No provider is added solely because it is advertised as free/unlimited.
- No routing decision may bypass Director policy, QA or budget limits.
- No token compression enters production without quality-loss testing by task category.
- No MITM/proxy interception feature enters production without explicit security review.
- Every route must emit provider/model, latency, retries, token usage, cost estimate and final status.
- One-switch rollback to Nexo-only path.
- Avoid double retries: define exactly one owner for transport retries and one owner for task-level re-execution.

## Initial recommendation
Do not replace Nexo. Evaluate OmniRoute as an optional Layer-2 routing/resilience component below the ContentFlow Director. Begin integration only after the Director's current task lifecycle, agent ranking, QA, memory, repair loop and observability are stable enough to provide a trustworthy baseline.

## Decision criterion
Adopt only if controlled tests show a net improvement in ContentFlow's accepted-task throughput, reliability or cost efficiency after accounting for added operational complexity and security surface.
