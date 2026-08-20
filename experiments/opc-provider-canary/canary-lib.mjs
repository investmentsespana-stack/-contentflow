export function validateCanaryConfig(config) {
  const requestCount = Number(config.requestCount);
  const maxOutputTokens = Number(config.maxOutputTokens);
  const maxUsd = Number(config.maxUsd);
  const maxPricePer1M = Number(config.maxPricePer1M);
  const estimatedInputTokens = Number(config.estimatedInputTokens ?? 64);

  if (!Number.isInteger(requestCount) || requestCount < 1 || requestCount > 5) throw new Error('CANARY_REQUEST_COUNT_OUT_OF_RANGE');
  if (!Number.isInteger(maxOutputTokens) || maxOutputTokens < 1 || maxOutputTokens > 256) throw new Error('CANARY_MAX_OUTPUT_TOKENS_OUT_OF_RANGE');
  if (!(maxUsd > 0 && maxUsd <= 0.50)) throw new Error('CANARY_MAX_USD_OUT_OF_RANGE');
  if (!(maxPricePer1M > 0)) throw new Error('CANARY_PRICE_REQUIRED');
  if (!Number.isInteger(estimatedInputTokens) || estimatedInputTokens < 1 || estimatedInputTokens > 512) throw new Error('CANARY_INPUT_ESTIMATE_OUT_OF_RANGE');

  const worstCaseTokens = requestCount * (estimatedInputTokens + maxOutputTokens);
  const worstCaseUsd = (worstCaseTokens / 1_000_000) * maxPricePer1M;
  if (worstCaseUsd > maxUsd) throw new Error('CANARY_BUDGET_PREFLIGHT_DENIED');

  return { requestCount, maxOutputTokens, maxUsd, maxPricePer1M, estimatedInputTokens, worstCaseTokens, worstCaseUsd };
}

export function estimateUsd(totalTokens, maxPricePer1M) {
  return (Number(totalTokens) / 1_000_000) * Number(maxPricePer1M);
}

export function sanitizeProviderResult(result) {
  return {
    ok: Boolean(result.ok),
    status: Number(result.status),
    latencyMs: Number(result.latencyMs),
    totalTokens: Number(result.totalTokens ?? 0),
    finishReason: result.finishReason ?? null,
  };
}
