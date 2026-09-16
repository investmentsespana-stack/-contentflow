# Super Estrategia Adaptativa — Architecture v0.9

Status: `IMPLEMENTED_SCAFFOLD_SHADOW_ONLY`

This increment formalizes the two research controls introduced from the reviewed videos without changing any preregistered trading rule.

## 1. Anti-overfitting governance — mandatory

Every strategy/parameter/coalition attempt must be recorded in the append-only experiment registry, including failed and rejected trials. Promotion is fail-closed and requires:

- Deflated Sharpe Ratio (DSR), with default research gate `DSR >= 0.95`;
- Probability of Backtest Overfitting (PBO) via CSCV;
- walk-forward evidence;
- untouched out-of-sample evidence;
- cost/execution stress;
- a valid experiment-registry hash chain.

The PBO promotion threshold is intentionally **not hard-coded**. Until the research policy explicitly sets it, promotion is blocked (`PBO_THRESHOLD_NOT_CONFIGURED`).

DSR/PSR use periodic, non-annualized Sharpe ratios at one consistent frequency. The trial population must contain all attempted variants, not only winners.

## 2. Price/order-flow + news/macro fusion

Pipeline:

`Market/Order Flow -> Market Encoder -> Query`

`News/Macro -> Finance Text Encoder (FinBERT-compatible adapter) -> Keys/Values`

`Point-in-Time Timestamp Guard -> Cross Attention -> Context Vector`

`Context/Regime + Strategy Pool -> Meta-Selector -> Risk Manager -> BUY/SELL/NO TRADE`

The finance text encoder never emits BUY/SELL directly. Cross-attention asks which *already available* news items are most relevant to the current market state.

### Point-in-time rule

A news item is visible only when both its source publication timestamp and our first-seen timestamp are `<= decision_time`. Future items are masked. Revisions must be stored as new events with their own availability time; revised values cannot overwrite history.

### Current execution status

The included attention block uses identity projections only to make the data contract executable and testable. It is explicitly tagged:

`SHADOW_ONLY_UNTRAINED_IDENTITY_PROJECTIONS`

It cannot authorize live orders. Learned query/key/value projections and the final expert-routing gate require training, calibration and the full robustness pipeline before promotion.

## 3. Existing research tracks are preserved

- User-rule baseline: BB14 touch -> later EMA3/9 cross -> EMA9 confirmation -> SAR, with EMA9/20 extension research.
- GitHub preregistered slope study: BB20 and its frozen discovery rules.

This v0.9 layer surrounds those tracks; it does not rewrite either rule set.

## 4. Director/RARA integration

New research task classes:

- `experiment_audit` -> robustness capability;
- `multimodal_context` -> multimodal fusion capability;
- `news_encoding` -> multimodal fusion capability.

RARA/QA must reject any promotion that lacks a complete trial registry, point-in-time provenance or required robustness evidence.

## 5. Safety state

`live_money = false`

`multimodal = shadow_only`

`missing point-in-time provenance = DATA_UNSAFE -> NO TRADE`

`missing DSR/PBO/OOS evidence = PROMOTION_BLOCKED`
