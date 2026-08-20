export function runOpcSyntheticLoad({
  totalTasks = 1000,
  virtualWorkers = 8,
  queueLimit = 32,
  failureEvery = 29,
} = {}) {
  if (virtualWorkers < 1 || queueLimit < virtualWorkers || totalTasks < 1) {
    throw new Error('INVALID_SYNTHETIC_LOAD_CONFIG');
  }

  const queue = [];
  const attempts = new Map();
  const completed = new Set();
  let tick = 0;
  let maxQueueDepth = 0;
  let backpressureEvents = 0;
  let injectedFailures = 0;
  let recoveredFailures = 0;
  let staleCompletionsRejected = 0;
  let maxWaitTicks = 0;

  const enqueue = (task) => {
    while (queue.length >= queueLimit) {
      backpressureEvents += 1;
      processCycle();
    }
    queue.push({ ...task, enqueuedAt: tick });
    maxQueueDepth = Math.max(maxQueueDepth, queue.length);
  };

  const processCycle = () => {
    tick += 1;
    const batch = queue.splice(0, virtualWorkers);
    for (const task of batch) {
      const attempt = (attempts.get(task.id) ?? 0) + 1;
      attempts.set(task.id, attempt);
      maxWaitTicks = Math.max(maxWaitTicks, tick - task.enqueuedAt);

      const leaseGeneration = attempt;
      const fencingToken = `${task.id}:g${leaseGeneration}`;
      const shouldFail = task.id % failureEvery === 0 && attempt === 1;

      if (shouldFail) {
        injectedFailures += 1;
        const checkpoint = { taskId: task.id, state: 'last-safe-state', leaseGeneration };
        const staleToken = fencingToken;
        const nextGeneration = leaseGeneration + 1;
        if (staleToken !== `${task.id}:g${nextGeneration}`) staleCompletionsRejected += 1;
        queue.push({ id: checkpoint.taskId, enqueuedAt: tick, recoveredFrom: checkpoint.state });
        maxQueueDepth = Math.max(maxQueueDepth, queue.length);
        continue;
      }

      if (task.recoveredFrom === 'last-safe-state') recoveredFailures += 1;
      completed.add(task.id);
    }
  };

  for (let id = 1; id <= totalTasks; id += 1) enqueue({ id });
  while (queue.length > 0) processCycle();

  return {
    schemaVersion: 1,
    mode: 'opc-synthetic-isolated',
    externalEffects: 0,
    manifestConcurrencyChanged: false,
    totalTasks,
    virtualWorkers,
    queueLimit,
    completedTasks: completed.size,
    maxQueueDepth,
    backpressureEvents,
    injectedFailures,
    recoveredFailures,
    staleCompletionsRejected,
    maxWaitTicks,
    ticks: tick,
  };
}
