export function chooseHealthyCandidate(candidates, failedDomain, requirements = {}) {
  const viable = candidates.filter((candidate) => {
    if (candidate.healthy !== true) return false;
    if (failedDomain && candidate.failureDomain === failedDomain) return false;
    if (requirements.taskClass && !(candidate.taskClasses ?? []).includes(requirements.taskClass)) return false;
    if (requirements.maxLatencyMs && candidate.latencyMs > requirements.maxLatencyMs) return false;
    return true;
  });

  if (!viable.length) return { selected: null, reason: "NO_HEALTHY_ALTERNATIVE" };

  viable.sort((a, b) => {
    const scoreA = (a.successRate ?? 0) * 100 - (a.latencyMs ?? 0) / 1000 - (a.costWeight ?? 0);
    const scoreB = (b.successRate ?? 0) * 100 - (b.latencyMs ?? 0) / 1000 - (b.costWeight ?? 0);
    return scoreB - scoreA;
  });

  return { selected: viable[0], reason: "ALTERNATIVE_SELECTED" };
}

export function sustainedAutonomyRun({ tasks, candidates, failurePlan }) {
  let incidents = 0;
  let autonomousRecoveries = 0;
  let completed = 0;
  let humanInterventions = 0;
  let rerouted = 0;
  const timeline = [];

  for (const task of tasks) {
    const failure = failurePlan[task.id];
    let domain = task.initialFailureDomain ?? null;

    if (failure) {
      incidents += 1;
      const route = chooseHealthyCandidate(candidates, domain, { taskClass: task.taskClass });
      if (!route.selected) {
        humanInterventions += 1;
        timeline.push({ taskId: task.id, status: "blocked", reason: route.reason });
        continue;
      }
      rerouted += 1;
      autonomousRecoveries += 1;
      timeline.push({ taskId: task.id, status: "recovered", fromDomain: domain, toDomain: route.selected.failureDomain, failure });
    }

    completed += 1;
    timeline.push({ taskId: task.id, status: "completed" });
  }

  return {
    totalTasks: tasks.length,
    completed,
    incidents,
    autonomousRecoveries,
    humanInterventions,
    rerouted,
    autonomyRate: incidents ? autonomousRecoveries / incidents : 1,
    completionRate: tasks.length ? completed / tasks.length : 1,
    timeline,
  };
}
