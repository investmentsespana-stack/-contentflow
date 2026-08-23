# ADR: Allowlist storage mechanism

Status: Accepted

Related dependency: `arch_runtime_atomic_claims` (builder run 1789)

## Decision

Use a platform-managed configuration service as the canonical allowlist source, with bounded runtime caching. The allowlist is versioned, auditable, fail-closed on fetch/validation failure, and every load records evidence correlated to the active builder/run context.

## Why

- Performance: cached reads keep authorization checks O(1) after initial load.
- Security: policy is not embedded as mutable runtime state in application code or images.
- Operations: allowlist changes can be versioned and rolled back without redeploying the whole application.
- Atomic claims alignment: policy version and evidence can be correlated to the claim lifecycle and idempotency key.

## Rejected alternatives

- In-code constants: require redeployment and make operational rollback slower.
- Deployment-bundled YAML/JSON as sole source: easier to audit but not dynamically revocable.

## Persistence path

This ADR is persisted at `docs/architecture/decisions/ADR-allowlist-storage-2098.md` in the ContentFlow architecture repository.
