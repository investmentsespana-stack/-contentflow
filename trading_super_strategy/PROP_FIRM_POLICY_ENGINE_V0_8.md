# Prop Firm Policy Engine — v0.8

Fecha de verificación: 2026-09-12

## Objetivo

Adaptar la Super Estrategia a las reglas operativas y de payout de firmas de fondeo sin alterar la lógica de mercado ni sacrificar robustez. La meta no es maximizar PnL bruto; es maximizar la probabilidad robusta de completar ciclos de evaluación/fondeo, conservar la cuenta y retirar beneficios de forma consistente.

## Principio central

Cada firma, plan y fase se trata como un perfil de restricciones diferente. El backtester debe ejecutar la misma estrategia bajo varios perfiles regulatorios/operativos y medir:

- probabilidad de completar evaluación;
- probabilidad de llegar a payout;
- probabilidad de breach por drawdown o daily loss;
- días esperados hasta payout;
- profit factor y expectancy neta;
- win rate;
- distribución diaria de PnL;
- mayor día / beneficio total;
- estabilidad OOS y walk-forward;
- sensibilidad a slippage, fills, latencia y costos.

## Reglas normalizadas que el motor debe entender

- `consistency_pct`
- `consistency_scope`: eval, funded, payout cycle o none
- `max_loss_type`: EOD trailing, intraday trailing, static
- `max_loss_distance`
- `daily_loss_limit`
- `daily_loss_soft_or_hard`
- `profit_target`
- `minimum_trading_days`
- `minimum_winning_days`
- `winning_day_threshold`
- `payout_buffer`
- `payout_cap`
- `profit_split`
- `contract_limit`
- `scaling_plan`
- `news_restrictions`
- `payout_reset_behavior`
- `inactivity_policy`

## Snapshot verificado de reglas relevantes

### Apex — productos nuevos 2026

- Evaluaciones nuevas: sin regla de consistencia en evaluación según la oferta pública actual.
- Performance Accounts nuevos: regla de consistencia del 50% para payout.
- El mayor día de beneficio debe quedar por debajo del 50% del beneficio neto acumulado del ciclo.
- La consistencia se reinicia después de payout.
- Apex anuncia explícitamente que los productos nuevos ya no aplican la antigua regla 5/1 de risk/reward ni la antigua regla MAE.
- Los límites de drawdown, contratos y payout dependen del producto/tamaño y deben cargarse por perfil específico.

### Topstep

- Trading Combine: Consistency Target del 50% respecto al profit target; excederlo no falla la cuenta, pero aumenta lo que falta para cumplir consistencia.
- Express Funded Standard: una sola regla dura principal de Maximum Loss Limit; payout exige 5 winning days de al menos $150 cada uno.
- Express Funded Consistency: payout con al menos 3 días y 40% de consistencia; el mayor día no puede superar 40% del beneficio neto del ciclo.
- Después de payout, el cálculo de consistencia y el contador de días se reinician.
- Scaling Plan y Maximum Loss Limit deben modelarse como state machine.

### MyFundedFutures

- Rapid y Pro evaluations: regla de consistencia del 50% en evaluación, salvo excepciones de productos indicadas por la firma.
- Rapid Sim Funded: sin consistency rule para payout; usa buffer y trailing max loss intradía que finalmente se bloquea.
- Pro Sim Funded: sin consistency rule; sin daily loss limit; payout después de buffer/tiempo según plan.
- T1 news trading está restringido en varios estados Sim Funded/Pro aunque pueda estar permitido durante evaluación.
- Debe modelarse separadamente Evaluation → Sim Funded → Live.

### Tradeify

- Select Evaluation: 40% de consistencia solo en evaluación.
- Select Funded: no consistency rule en los planes Select actuales indicados por la firma.
- Growth Sim Funded: 35% de consistencia.
- Lightning Funded: 20% primer payout, 25% segundo, 30% tercero+ para cuentas nuevas dentro de la política indicada.
- Trailing Max Drawdown: se actualiza EOD pero se hace cumplir en tiempo real contra Net Liquidation Value.
- Algunos planes tienen Daily Loss Limit y otros no.
- Debe modelarse también hedging/correlated-product policy y restricciones específicas por plan.

### Take Profit Trader

- Test/Evaluation: consistency rule del 50%; no produce fallo inmediato, sino que obliga a seguir operando hasta volver a cumplir.
- PRO: sin consistency rule.
- PRO: intraday drawdown y restricciones de news trading en eventos importantes específicos.
- PRO permite payouts desde el primer día según la política publicada actual.

## Implicaciones para la Super Estrategia

### 1. Ratios negativos sí, pero como candidato, no como regla

El buscador debe probar relaciones riesgo/beneficio como:

- 1:0.25
- 1:0.40
- 1:0.50
- 1:0.70
- 1:1
- 1:1.5
- 1:2
- 1:3

Un ratio negativo puede aumentar el win rate y suavizar la distribución diaria de beneficios, lo que puede ayudar con consistencia. Pero una pérdida grande relativa al beneficio medio puede acercar peligrosamente al trailing drawdown. Por eso el criterio no será `max win rate`, sino `max payout survival probability` con EV neto positivo.

### 2. Objetivo diferente según firma/plan

Nueva función objetivo por perfil:

`PropFirmFitness = payout_probability + survival_probability + robust_EV + consistency_score - breach_risk - drawdown_penalty - cost_penalty`

No usar solo profit neto o win rate.

### 3. Soft daily profit target

Para cuentas con consistency rule, el sistema puede limitar exposición o dejar de abrir nuevas operaciones cuando el beneficio diario ya representa una fracción elevada del beneficio total del ciclo. Esto no debe forzar cierres irracionales; sirve para evitar crear un día excepcional que retrase el payout.

### 4. Dynamic Risk Budget

El riesgo por trade se calcula también con:

`distance_to_drawdown`, `daily_loss_remaining`, `payout_buffer`, `consistency_headroom`, `days_in_cycle`, `current_cycle_profit`.

El riesgo permitido debe disminuir si el margen al drawdown se comprime.

### 5. Firm-aware Coalition Router

Una coalición puede ser excelente en cuenta propia pero inadecuada para una firma concreta. El backtester debe producir rankings separados por:

- instrumento;
- LONG / SHORT;
- sesión;
- volatilidad;
- régimen;
- firma;
- plan;
- fase: evaluation / funded / live.

### 6. Simulación exacta de reglas

Cada backtest de fondeo debe simular una máquina de estados de cuenta:

`START → EVAL → PASS → FUNDED → PAYOUT_CYCLE_n → PAYOUT → NEXT_CYCLE → LIVE/FAIL`

Debe mover el drawdown exactamente según el tipo de regla, contar días, aplicar resets y bloquear trades prohibidos por news/horario/contratos.

## Robustez obligatoria

Ninguna estrategia o coalición se promueve por ajustarse a una sola firma. Debe pasar:

- Train / Validation / OOS;
- Walk-Forward;
- Monte Carlo;
- bootstrap/reordenamiento de trades;
- missed trades;
- slippage/cost stress;
- parameter perturbation;
- latency/fill stress;
- strategy dropout dentro de coaliciones;
- CSCV/PBO;
- Deflated Sharpe Ratio;
- stress por régimen.

## Métricas nuevas para fondeo

- account survival rate;
- probability of first payout;
- probability of 3 consecutive payouts;
- median days to payout;
- 95% drawdown percentile;
- consistency breach/delay frequency;
- daily PnL concentration;
- expected payout per 30/60/90 days;
- payout-adjusted expectancy;
- live-transition probability cuando aplique.

## Regla de seguridad

El sistema nunca modificará una estrategia rentable para “cumplir” una firma si eso vuelve negativo su EV OOS. Si las reglas de una firma son incompatibles con el edge de una coalición, esa coalición se marca `NOT_SUITABLE_FOR_PROFILE` y se usa otra o se hace NO TRADE.

## Próximo bloque de implementación

1. Crear perfiles JSON versionados por firma/plan/fase.
2. Construir `PropFirmPolicyEngine` y state machine de cuenta.
3. Integrarlo con Coalition Backtester.
4. Añadir búsqueda de RR y profit targets condicionada a perfil.
5. Medir payout survival probability y time-to-payout.
6. Validar todo con Monte Carlo/OOS/Walk-Forward antes de paper.
