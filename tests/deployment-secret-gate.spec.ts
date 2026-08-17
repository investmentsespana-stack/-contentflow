import { test, expect } from '@playwright/test';
import { evaluateDeploymentSecretGate, assertDeploymentSecretGate } from '../src/guardrails/deployment-secret-gate';

test.describe('deployment secret gate', () => {
  const safeStatic = { source: 'static' as const, passed: true, evidenceRef: 'ci://static-secret-scan/ok' };
  const safeRuntime = { source: 'runtime' as const, passed: true, evidenceRef: 'runtime://secret-trace/ok' };

  test('allows deployment only when static and runtime checks pass with evidence', () => {
    expect(evaluateDeploymentSecretGate(safeStatic, safeRuntime)).toEqual({
      allowed: true,
      reason: 'ALL_SECRET_CHECKS_PASSED',
      failedSources: [],
    });
    expect(() => assertDeploymentSecretGate(safeStatic, safeRuntime)).not.toThrow();
  });

  test('blocks deployment when static analysis flags unsafe secret handling', () => {
    const unsafeStatic = {
      source: 'static' as const,
      passed: false,
      findings: ['hardcoded_secret'],
      evidenceRef: 'ci://static-secret-scan/fail',
    };
    expect(evaluateDeploymentSecretGate(unsafeStatic, safeRuntime)).toEqual({
      allowed: false,
      reason: 'STATIC_SECRET_CHECK_FAILED',
      failedSources: ['static'],
    });
    expect(() => assertDeploymentSecretGate(unsafeStatic, safeRuntime)).toThrow(/DEPLOYMENT_SECRET_GATE_BLOCKED:STATIC_SECRET_CHECK_FAILED/);
  });

  test('blocks deployment when runtime instrumentation flags unsafe secret handling', () => {
    const unsafeRuntime = {
      source: 'runtime' as const,
      passed: false,
      findings: ['secret_exposed_in_trace'],
      evidenceRef: 'runtime://secret-trace/fail',
    };
    expect(evaluateDeploymentSecretGate(safeStatic, unsafeRuntime)).toEqual({
      allowed: false,
      reason: 'RUNTIME_SECRET_CHECK_FAILED',
      failedSources: ['runtime'],
    });
  });

  test('fails closed when passing checks do not include evidence references', () => {
    const noEvidenceStatic = { source: 'static' as const, passed: true };
    const decision = evaluateDeploymentSecretGate(noEvidenceStatic, safeRuntime);
    expect(decision.allowed).toBe(false);
    expect(decision.reason).toBe('SECRET_CHECK_EVIDENCE_MISSING');
  });

  test('blocks if both checks fail and reports both sources', () => {
    const staticFail = { source: 'static' as const, passed: false, evidenceRef: 'ci://static/fail' };
    const runtimeFail = { source: 'runtime' as const, passed: false, evidenceRef: 'runtime://trace/fail' };
    const decision = evaluateDeploymentSecretGate(staticFail, runtimeFail);
    expect(decision.allowed).toBe(false);
    expect(decision.failedSources).toEqual(['static', 'runtime']);
  });
});
