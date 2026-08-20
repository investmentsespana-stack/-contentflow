# Director Foundation v2 — ContentFlow + OPC

Status: experimental baseline. No production deployment.

## Goal

ContentFlow and OPC remain independent Directors, but share a small deterministic foundation for safety, recovery and conformance. The shared layer does not expose project-private memory or workflow internals and does not create a Master Director.

## Shared invariants

1. One project Director remains the authoritative writer for protected project state.
2. Cross-project state, memory, tools and credentials are denied by default.
3. Observe-only SDC endpoints expose normalized status without mutation.
4. Every mutating execution requires idempotency, expected generation and lease/fencing ownership.
5. High-risk or external-effect operations require a bound approval reference and payload hash.
6. External effects require evidence before completion can be accepted.
7. Unknown failures fail closed and route to diagnosis instead of blind retry.
8. Stale workers cannot publish accepted results after losing their fencing token.
9. Recovery is selected from a deterministic failure-policy registry.
10. Stable promotion requires tests and runtime evidence; experimental branches never self-promote.

## Recovery flow

`observe -> classify -> acquire/verify ownership -> choose recovery policy -> repair/retry -> verify evidence -> reconcile -> continue`

The canonical recovery policy lives in `src/director-contract/recovery-policy.mjs`.

## Execution safety flow

`intent -> project boundary -> operation/risk class -> authorization -> idempotency -> generation -> lease/fencing -> execute -> evidence -> accept/reject result`

The canonical validator lives in `src/director-contract/execution-safety.mjs`.

## ContentFlow

ContentFlow keeps its existing Director/RARA separation. Foundation v2 is an adapter/guard layer, not a rewrite. The experimental manifest is `projects/contentflow/director-manifest.v1.json`.

## OPC

OPC remains sandboxed with concurrency `0` and `externalEffectsEnabled=false`. Its deterministic workflow skeleton is `projects/opc/workflow.v1.json`. Protected transitions already declare approval, idempotency, fencing and evidence requirements before any external integration is allowed.

## Baseline synchronization rule

Experimental work must start from a recent `main` baseline. Stable fixes and proven safety contracts may flow from Stable to experiments. Experimental features flow back to Stable only through explicit validation and promotion. Benchmarks are invalid if the compared branches have materially different safety baselines.

## Promotion gates

Before any runtime mutation is enabled:

- SDC conformance passes for both Directors.
- recovery-policy tests pass.
- execution-safety tests pass.
- stale fencing tokens are rejected.
- external effects prove idempotency and evidence capture in sandbox.
- no cross-project access is introduced.
- no Master Director dependency is required.
