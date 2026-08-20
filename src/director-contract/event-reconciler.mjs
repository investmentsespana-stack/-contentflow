const KNOWN_REPAIRS = new Map([
  ["lease_expired", "reclaim_and_reassign"],
  ["worker_timeout", "reclaim_and_reassign"],
  ["rate_limited", "bounded_backoff"],
  ["dependency_recovered", "resume_blocked_work"],
  ["state_drift", "reconcile_desired_state"],
]);

export function eventToReconciliation(event) {
  const type = event?.type;
  if (!type) return { actionable: false, reason: "INVALID_EVENT" };
  const action = KNOWN_REPAIRS.get(type);
  if (!action) {
    return {
      actionable: true,
      repairAuthority: "director",
      action: "fail_closed_and_diagnose",
      known: false,
      eventId: event.id ?? null,
    };
  }
  return {
    actionable: true,
    repairAuthority: "rara",
    action,
    known: true,
    eventId: event.id ?? null,
  };
}

export function raraCanExecute(decision, context = {}) {
  if (!decision?.known || decision.repairAuthority !== "rara") return false;
  if (context.crossProjectAccess === true) return false;
  if (context.externalEffect === true) return false;
  if (!context.idempotencyKey) return false;
  if (!Number.isInteger(context.expectedGeneration) || context.expectedGeneration < 1) return false;
  if (!context.leaseId || !Number.isInteger(context.fencingToken)) return false;
  return true;
}

export function reconcileEvent(event, context = {}) {
  const decision = eventToReconciliation(event);
  if (!decision.actionable) return { status: "ignored", ...decision };

  if (decision.repairAuthority === "rara") {
    if (!raraCanExecute(decision, context)) {
      return { status: "blocked", reason: "RARA_GUARDRAIL_BLOCK", ...decision };
    }
    return {
      status: "repaired",
      actor: "rara",
      continueWork: true,
      evidenceRequired: true,
      ...decision,
    };
  }

  return {
    status: "diagnosis_required",
    actor: "director",
    continueWork: false,
    evidenceRequired: true,
    ...decision,
  };
}

export function autonomyOutcome(events, contextFactory) {
  const results = events.map((event, index) =>
    reconcileEvent(event, contextFactory(event, index)),
  );
  const repaired = results.filter((x) => x.status === "repaired").length;
  return {
    results,
    repaired,
    total: results.length,
    autonomyRate: results.length ? repaired / results.length : 0,
  };
}
