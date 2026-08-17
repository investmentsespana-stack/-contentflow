# Standard Director Contract v1 (SDC-v1)

Status: IMPLEMENTATION CANDIDATE — phase 1 observe-only.

## Purpose

SDC-v1 is the stable control-plane contract that independent project Directors expose to a future Master Director. It does not replace a project Director and does not grant the Master direct access to project-internal tables, memory, tools, or workflow state.

## Core principles

- Director authority remains local to its project.
- `spec` expresses desired state; `status` reports observed state.
- `generation` changes when desired state changes; `observedGeneration` identifies which generation the reported state reflects.
- Protected state transitions remain deterministic.
- Every future mutating command must be authenticated, authorized, idempotent, version-aware, correlation-aware, and evidence-producing.
- Cross-project memory/data access is denied by default.
- Phase 1 is observe-only. No control command is enabled by this adapter.

## Requirement levels

### MUST

- `contract.schemaName`
- `contract.apiVersion`
- `contract.contractVersion`
- `metadata.directorId`
- `metadata.projectId`
- `metadata.projectType`
- `metadata.environment`
- `metadata.generation`
- `spec.lifecycleState`
- `spec.autonomyLevel`
- `spec.capacity.concurrencyLimit`
- `status.phase`
- `status.health`
- `status.observedGeneration`
- `status.lastObservedAt`
- `conditions[]` with `type`, `status`, `reason`, `message`, `severity`, `lastTransitionTime`, `observedGeneration`
- `capabilities.supportedTaskClasses`
- `capabilities.acceptedCommands`
- `security.projectBoundary`
- `security.allowedScopes`
- `observability.traceable`
- `observability.evidenceBacked`
- `compatibility.minMasterContractVersion`
- `compatibility.maxMasterContractVersion`

### SHOULD

- owner and labels/tags
- budget and rate-limit policy
- backlog/active-work/capacity counters
- quality/autonomy KPIs
- dependency health
- checkpoint/recovery state
- standard event/evidence envelope
- capability/tool/dependency registry references
- human escalation summary

### OPTIONAL

- A2A interoperability profile
- streaming status/watch interface
- workload trust-domain metadata
- advanced policy-constrained authorization claims

## Canonical shape

```json
{
  "contract": {
    "schemaName": "standard-director-contract",
    "apiVersion": "v1",
    "contractVersion": "1.0.0",
    "mode": "observe-only"
  },
  "metadata": {
    "directorId": "contentflow-director",
    "projectId": "contentflow",
    "projectType": "software-orchestration",
    "environment": "production",
    "generation": 1
  },
  "spec": {
    "lifecycleState": "running",
    "autonomyLevel": "bounded-autonomous",
    "capacity": { "concurrencyLimit": 2 }
  },
  "status": {
    "phase": "running",
    "health": "Unknown",
    "observedGeneration": 1,
    "lastObservedAt": "RFC3339"
  },
  "conditions": [],
  "capabilities": {
    "supportedTaskClasses": [],
    "acceptedCommands": []
  },
  "security": {
    "projectBoundary": "contentflow",
    "allowedScopes": ["observe"]
  },
  "observability": {
    "traceable": true,
    "evidenceBacked": true
  },
  "compatibility": {
    "minMasterContractVersion": "1.0.0",
    "maxMasterContractVersion": "1.x"
  }
}
```

## Phase 1 conformance gate

A Director is `SDC-v1 observe compliant` only when:

1. the adapter performs no writes or mutating RPCs;
2. the response validates required fields and version metadata;
3. `generation/observedGeneration` are present;
4. health is expressed through normalized conditions;
5. project boundary is explicit;
6. evidence/trace capability is declared without exposing private internals;
7. unavailable probes degrade individual conditions instead of fabricating success;
8. ContentFlow and OPC can expose the same shape independently.

## Future mutation gate

Commands such as `pause`, `resume`, `drain`, `reconcile`, `reprioritize`, `set_capacity`, and `set_budget` remain disabled until a later phase proves authentication, authorization, idempotency, `expected_generation`, correlation IDs, audit evidence, and rollback/recovery behavior.
