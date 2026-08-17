# OPC — Independent Director Project

Status: OPEN / BOOTSTRAP.

OPC is intentionally opened as an independent project Director. It is not embedded inside the ContentFlow Director and it is not yet connected to a Master Director.

## Architectural boundary

- Project id: `opc`
- Director id: `opc-director`
- Contract: `SDC-v1`
- Initial mode: `observe-only / mock`
- Memory boundary: OPC-only
- Tool/credential boundary: OPC-only
- Future shared infrastructure is accessed through explicit capabilities and policy, never through direct cross-project state access.

## Initial workflow domains

1. Lead acquisition
2. Qualification
3. Sales conversation
4. Quote/proposal
5. Approval gates
6. CRM/customer state
7. Scheduling/order/payment handoff
8. Follow-up/support
9. Exception/human escalation

Critical business effects must remain deterministic and idempotent. Agents may reason inside bounded workflow steps but do not independently create protected state transitions.

## Director bootstrap stages

### Stage A — Contract mock

Expose the SDC-v1 shape with no external side effects.

### Stage B — Deterministic workflow skeleton

Model business phases, accepted transitions, evidence requirements, retries, idempotency, approvals, and recovery boundaries.

### Stage C — Capability registry

Register specialized sales, qualification, support, CRM and operations capabilities using measured evidence rather than self-declared skill labels.

### Stage D — Sandbox execution

Run synthetic leads/orders and prove isolation, recovery, evidence-backed completion and no duplicate side effects.

### Stage E — External integrations

Only after conformance: CRM, messaging/WhatsApp, scheduling, payments and other business tools behind least-privilege policies and explicit approval rules.

## Master readiness gate

OPC must not connect to a future Master until both OPC and ContentFlow independently pass the SDC-v1 conformance suite.
