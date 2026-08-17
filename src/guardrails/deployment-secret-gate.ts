export type SecretSafetyCheck = {
  source: 'static' | 'runtime';
  passed: boolean;
  findings?: readonly string[];
  evidenceRef?: string | null;
};

export type DeploymentSecretGateDecision = {
  allowed: boolean;
  reason: 'ALL_SECRET_CHECKS_PASSED' | 'STATIC_SECRET_CHECK_FAILED' | 'RUNTIME_SECRET_CHECK_FAILED' | 'SECRET_CHECK_EVIDENCE_MISSING';
  failedSources: Array<'static' | 'runtime'>;
};

function hasEvidence(check: SecretSafetyCheck): boolean {
  return typeof check.evidenceRef === 'string' && check.evidenceRef.trim().length > 0;
}

export function evaluateDeploymentSecretGate(
  staticCheck: SecretSafetyCheck,
  runtimeCheck: SecretSafetyCheck,
): DeploymentSecretGateDecision {
  if (staticCheck.source !== 'static' || runtimeCheck.source !== 'runtime') {
    throw new Error('DEPLOYMENT_SECRET_GATE_INVALID_CHECK_SOURCES');
  }

  const failedSources: Array<'static' | 'runtime'> = [];
  if (!staticCheck.passed) failedSources.push('static');
  if (!runtimeCheck.passed) failedSources.push('runtime');

  if (failedSources.includes('static')) {
    return { allowed: false, reason: 'STATIC_SECRET_CHECK_FAILED', failedSources };
  }
  if (failedSources.includes('runtime')) {
    return { allowed: false, reason: 'RUNTIME_SECRET_CHECK_FAILED', failedSources };
  }
  if (!hasEvidence(staticCheck) || !hasEvidence(runtimeCheck)) {
    return { allowed: false, reason: 'SECRET_CHECK_EVIDENCE_MISSING', failedSources: [] };
  }

  return { allowed: true, reason: 'ALL_SECRET_CHECKS_PASSED', failedSources: [] };
}

export function assertDeploymentSecretGate(
  staticCheck: SecretSafetyCheck,
  runtimeCheck: SecretSafetyCheck,
): void {
  const decision = evaluateDeploymentSecretGate(staticCheck, runtimeCheck);
  if (!decision.allowed) {
    throw new Error(`DEPLOYMENT_SECRET_GATE_BLOCKED:${decision.reason}:${decision.failedSources.join(',')}`);
  }
}
