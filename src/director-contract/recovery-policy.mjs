export const FAILURE_CLASSES = Object.freeze([
  "format_violation",
  "missing_required_field",
  "secret_exposure",
  "authorization_denied",
  "rate_limited",
  "dependency_unavailable",
  "worker_timeout",
  "lease_lost",
  "state_drift",
  "evidence_missing",
  "unknown",
]);

export const RECOVERY_POLICIES = Object.freeze({
  format_violation: { retryable: false, action: "reject_input", owner: "requester", maxAttempts: 0, requiresHuman: false },
  missing_required_field: { retryable: false, action: "request_input_repair", owner: "requester", maxAttempts: 0, requiresHuman: false },
  secret_exposure: { retryable: false, action: "quarantine_and_rotate", owner: "security", maxAttempts: 0, requiresHuman: true },
  authorization_denied: { retryable: false, action: "fail_closed", owner: "policy", maxAttempts: 0, requiresHuman: true },
  rate_limited: { retryable: true, action: "retry_after_backoff", owner: "director", maxAttempts: 3, requiresHuman: false },
  dependency_unavailable: { retryable: true, action: "circuit_break_and_retry", owner: "director", maxAttempts: 3, requiresHuman: false },
  worker_timeout: { retryable: true, action: "reclaim_lease_and_reassign", owner: "director", maxAttempts: 2, requiresHuman: false },
  lease_lost: { retryable: false, action: "fence_stale_worker", owner: "director", maxAttempts: 0, requiresHuman: false },
  state_drift: { retryable: true, action: "reconcile_desired_state", owner: "director", maxAttempts: 2, requiresHuman: false },
  evidence_missing: { retryable: false, action: "block_completion", owner: "qa", maxAttempts: 0, requiresHuman: false },
  unknown: { retryable: false, action: "fail_closed_and_diagnose", owner: "rara", maxAttempts: 0, requiresHuman: true },
});

export function normalizeFailureClass(value) {
  return FAILURE_CLASSES.includes(value) ? value : "unknown";
}

export function classifyFailure(signal = {}) {
  const explicit = normalizeFailureClass(signal.failureClass);
  if (explicit !== "unknown" || signal.failureClass === "unknown") return explicit;

  const code = String(signal.code || "").toLowerCase();
  const status = Number(signal.status || 0);
  const kind = String(signal.kind || "").toLowerCase();

  if (status === 429 || code.includes("rate_limit") || code.includes("too_many_requests")) return "rate_limited";
  if (status === 401 || status === 403 || code.includes("unauthorized") || code.includes("forbidden")) return "authorization_denied";
  if (code.includes("secret") || kind === "secret_exposure") return "secret_exposure";
  if (code.includes("lease") || kind === "lease_lost") return "lease_lost";
  if (code.includes("timeout") || kind === "worker_timeout") return "worker_timeout";
  if (code.includes("dependency") || code.includes("unavailable") || status === 502 || status === 503 || status === 504) return "dependency_unavailable";
  if (code.includes("evidence") || kind === "evidence_missing") return "evidence_missing";
  if (code.includes("drift") || kind === "state_drift") return "state_drift";
  if (code.includes("missing_required") || kind === "missing_required_field") return "missing_required_field";
  if (code.includes("format") || code.includes("malformed") || kind === "format_violation") return "format_violation";
  return "unknown";
}

export function recoveryDecision(signal = {}) {
  const failureClass = classifyFailure(signal);
  return { failureClass, ...RECOVERY_POLICIES[failureClass] };
}
