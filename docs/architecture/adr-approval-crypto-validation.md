# ADR: Approval Cryptographic Validation Interface

Status: Accepted

## Context

Deploy/completion approval records must fail closed until their integrity and authenticity are cryptographically validated against the exact change context. Validation must be deterministic, typed, auditable, and independent from unverified model output.

## Decision

The canonical interface is `ApprovalCryptoValidator.validate(record, context): Promise<ApprovalCryptoValidationResult>`.

`ApprovalCryptoRecord` carries the approval identity, change identity, payload hash, signature, signer key identifier, and algorithm. `ApprovalChangeContext` carries the expected change identity and expected payload hash.

The validation result contains `valid` plus a machine-readable reason. The interface stub MUST fail closed with `not_implemented` until signature and hash verification are implemented by later tasks.

No approval may be treated as valid merely because a record exists. Implementations must reject change-id mismatch, payload-hash mismatch, invalid signatures, unsupported algorithms, or unavailable verification material.

## Interface contract

```ts
interface ApprovalCryptoValidator {
  validate(
    record: ApprovalCryptoRecord,
    context: ApprovalChangeContext,
  ): Promise<ApprovalCryptoValidationResult>;
}
```

The canonical source location is `src/platform/approval-crypto-validator.ts`.
