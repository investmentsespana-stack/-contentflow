import fs from 'node:fs';
import { performance } from 'node:perf_hooks';
import { estimateUsd, sanitizeProviderResult, validateCanaryConfig } from './canary-lib.mjs';

const required = (name) => {
  const value = process.env[name];
  if (!value) throw new Error(`${name}_REQUIRED`);
  return value;
};

const apiKey = required('NEXOROUTER_API_KEY_SECUNDARY');
const baseUrl = required('NEXOROUTER_BASE_URL').replace(/\/$/, '');
const model = required('NEXOROUTER_CANARY_MODEL');
const cfg = validateCanaryConfig({
  requestCount: process.env.OPC_CANARY_REQUESTS ?? 3,
  maxOutputTokens: process.env.OPC_CANARY_MAX_OUTPUT_TOKENS ?? 128,
  maxUsd: process.env.OPC_CANARY_MAX_USD ?? 0.25,
  maxPricePer1M: required('OPC_CANARY_MAX_PRICE_PER_1M_TOKENS'),
  estimatedInputTokens: process.env.OPC_CANARY_ESTIMATED_INPUT_TOKENS ?? 64,
});

const evidence = {
  schemaVersion: 1,
  experiment: 'opc-provider-canary',
  projectId: 'opc',
  productionWrites: false,
  externalToolsEnabled: false,
  concurrency: 1,
  limits: cfg,
  requests: [],
  totals: { tokens: 0, estimatedUsd: 0, successes: 0, failures: 0 },
};

for (let i = 0; i < cfg.requestCount; i += 1) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 20_000);
  const started = performance.now();
  try {
    const response = await fetch(`${baseUrl}/chat/completions`, {
      method: 'POST',
      signal: controller.signal,
      headers: {
        authorization: `Bearer ${apiKey}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        model,
        temperature: 0,
        max_tokens: cfg.maxOutputTokens,
        messages: [
          { role: 'system', content: 'You are an isolated OPC canary. Do not call tools, write external state, or reveal secrets.' },
          { role: 'user', content: `Return exactly: OPC_CANARY_OK_${i + 1}` },
        ],
      }),
    });
    const body = await response.json().catch(() => ({}));
    const latencyMs = Math.round(performance.now() - started);
    const totalTokens = Number(body?.usage?.total_tokens ?? 0);
    evidence.totals.tokens += totalTokens;
    evidence.totals.estimatedUsd = estimateUsd(evidence.totals.tokens, cfg.maxPricePer1M);
    if (evidence.totals.estimatedUsd > cfg.maxUsd) throw new Error('CANARY_RUNTIME_BUDGET_EXCEEDED');

    const result = sanitizeProviderResult({
      ok: response.ok,
      status: response.status,
      latencyMs,
      totalTokens,
      finishReason: body?.choices?.[0]?.finish_reason ?? null,
    });
    evidence.requests.push(result);
    if (response.ok) evidence.totals.successes += 1;
    else evidence.totals.failures += 1;
  } catch (error) {
    evidence.totals.failures += 1;
    evidence.requests.push({ ok: false, status: 0, latencyMs: Math.round(performance.now() - started), totalTokens: 0, finishReason: null, errorCode: error instanceof Error ? error.message : 'UNKNOWN' });
    if (error instanceof Error && error.message === 'CANARY_RUNTIME_BUDGET_EXCEEDED') break;
  } finally {
    clearTimeout(timer);
  }
}

fs.mkdirSync('certification-evidence', { recursive: true });
fs.writeFileSync('certification-evidence/opc-provider-canary-evidence.json', `${JSON.stringify(evidence, null, 2)}\n`, 'utf8');

if (evidence.totals.failures > 0 || evidence.totals.successes !== cfg.requestCount) process.exitCode = 1;
