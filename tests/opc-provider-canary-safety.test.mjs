import test from 'node:test';
import assert from 'node:assert/strict';
import { estimateUsd, sanitizeProviderResult, validateCanaryConfig } from '../experiments/opc-provider-canary/canary-lib.mjs';

test('OPC provider canary enforces hard request, token and dollar ceilings before execution', () => {
  const cfg = validateCanaryConfig({ requestCount: 3, maxOutputTokens: 128, maxUsd: 0.25, maxPricePer1M: 20, estimatedInputTokens: 64 });
  assert.equal(cfg.requestCount, 3);
  assert.ok(cfg.worstCaseUsd <= 0.25);
  assert.throws(() => validateCanaryConfig({ requestCount: 6, maxOutputTokens: 128, maxUsd: 0.25, maxPricePer1M: 20 }), /CANARY_REQUEST_COUNT_OUT_OF_RANGE/);
  assert.throws(() => validateCanaryConfig({ requestCount: 3, maxOutputTokens: 300, maxUsd: 0.25, maxPricePer1M: 20 }), /CANARY_MAX_OUTPUT_TOKENS_OUT_OF_RANGE/);
  assert.throws(() => validateCanaryConfig({ requestCount: 3, maxOutputTokens: 128, maxUsd: 1, maxPricePer1M: 20 }), /CANARY_MAX_USD_OUT_OF_RANGE/);
});

test('OPC provider canary fails closed when worst-case token spend exceeds configured budget', () => {
  assert.throws(() => validateCanaryConfig({ requestCount: 5, maxOutputTokens: 256, maxUsd: 0.01, maxPricePer1M: 100, estimatedInputTokens: 512 }), /CANARY_BUDGET_PREFLIGHT_DENIED/);
});

test('provider evidence excludes response content and credentials', () => {
  const sanitized = sanitizeProviderResult({ ok: true, status: 200, latencyMs: 123, totalTokens: 42, finishReason: 'stop', content: 'secret payload', apiKey: 'never-log-me' });
  assert.deepEqual(sanitized, { ok: true, status: 200, latencyMs: 123, totalTokens: 42, finishReason: 'stop' });
  assert.equal(estimateUsd(1000, 20), 0.02);
});
