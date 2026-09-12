# Super Estrategia Adaptativa — Master Execution Plan v0.7

Fecha: 2026-09-12

## Objetivo

Construir un sistema adaptativo conectado 24x5, primero en research/paper/shadow, que detecte contexto de mercado, descubra mediante backtesting combinaciones óptimas de estrategias compatibles, mantenga coaliciones LONG y SHORT separadas cuando estadísticamente sea superior, seleccione dinámicamente el grupo con mayor edge, ejecute una sola posición coordinada y calcule entrada, stop, target, parciales, trailing y time-exit de forma adaptativa.

NO TRADE es una decisión válida. Live money permanece prohibido hasta superar validación robusta, paper y shadow.

## Principio central

No buscamos una estrategia universal. Buscamos un conjunto de coaliciones especializadas y robustas, descubiertas por backtesting combinatorio y activadas por régimen.

## Frentes de trabajo

### 1. Data & Replay
- Databento GLBX.MDP3 para NQ/ES/YM/RTY.
- Escalado de 1m a 1s, trades y MBP-1; MBO solo si aporta valor incremental.
- Normalización de timestamps, roll de contratos, costos y calidad de datos.
- Recorder/replay para reproducir cada decisión.

### 2. Strategy Registry & Factory
Familias iniciales:
- momentum;
- breakout/breakdown;
- mean reversion;
- VWAP;
- liquidity sweep;
- order flow;
- volatility;
- opening drive/reversal;
- trend continuation/pullback;
- event reaction;
- cross-market;
- hybrid.

Cada estrategia registra familia, principios, LONG/SHORT por separado, condiciones de entrada, invalidación, horizonte, régimen preferido, targets candidatos y métricas train/validation/OOS.

### 3. Context / Regime / Session Engine
Features:
- sesión y minutos desde apertura;
- volatilidad y rango;
- tendencia/lateralidad;
- estructura/liquidez;
- flow/volume;
- cross-market NQ/ES/YM/RTY;
- macro/event risk;
- gaps, overnight high/low, VWAP y opening behavior.

Estados mínimos:
- bullish trend;
- bearish trend;
- range/low-vol;
- expansion/high-vol;
- event-driven;
- uncertain/data-unsafe.

### 4. Coalition Backtester / Synergy Search
Para cada contexto:
- evaluar cada estrategia individual;
- separar LONG y SHORT;
- probar pares, tríos y cuádruples;
- escalar a búsqueda heurística/genética cuando N sea grande;
- rechazar conflictos de dirección, principio o target;
- medir correlación de errores y redundancia;
- calcular win-rate uplift versus mejor miembro individual;
- medir EV, PF, DD, MAE/MFE, duración, costos, slippage y contradiction rate;
- producir Top-K coaliciones por contexto, no una sola ganadora universal.

Salidas:
- best_long_coalitions[context];
- best_short_coalitions[context];
- no_trade_contexts[context].

### 5. Probability + Adaptive Risk/Reward + Exit Engine
Por cada trade estimar:
- P(target antes de stop) para 0.25R, 0.5R, 0.75R, 1R, 1.5R, 2R, 3R y 4R;
- P(stop antes de target);
- expected value neto;
- MFE/MAE esperado;
- duración esperada;
- incertidumbre.

Debe permitir ratios negativos cuando el EV neto y la robustez lo justifiquen.

Salida única por posición:
- entry;
- stop;
- size;
- target/partials;
- trailing;
- time-exit;
- invalidation.

### 6. Fundamental / Macro Intelligence
No envía órdenes. Produce features point-in-time como direction_bias, event_risk, hawkish_dovish, growth/inflation/liquidity, shock_probability, confidence y decay.

### 7. Meta-Selector / Router
Proceso:
context -> candidate coalitions -> probability/EV -> uncertainty -> risk -> BUY/SELL/NO TRADE.

Debe poder seleccionar una coalición LONG, una SHORT o ninguna.

## 8. Robustness Gate — obligatorio

Ninguna estrategia ni coalición puede promoverse por un backtest único. Debe pasar una batería de robustez.

### A. Train / Validation / Out-of-Sample
- train para búsqueda;
- validation para selección;
- OOS completamente reservado para confirmación final;
- prohibido reajustar repetidamente sobre el mismo OOS.

### B. Walk-Forward Analysis
- ventanas móviles y expansivas;
- recalibrar solo con datos previos;
- exigir estabilidad de WR, EV, PF, DD y selección de coalición a través del tiempo.

### C. Monte Carlo
Aplicar múltiples familias de simulación:
1. reshuffle de orden de trades;
2. bootstrap con reemplazo de trades;
3. perturbación de retornos/resultado por trade;
4. variación de slippage y comisiones;
5. retraso aleatorio de entrada/salida;
6. omisión aleatoria de operaciones;
7. variación de fill parcial;
8. perturbación de secuencias ganadoras/perdedoras;
9. stress de drawdown y losing streaks;
10. simulaciones específicas por régimen.

Registrar distribuciones, no solo promedios:
- mediana y percentiles 5/25/75/95;
- max drawdown simulado;
- probabilidad de ruina;
- probabilidad de EV <= 0;
- probabilidad de PF < 1;
- peor racha esperada;
- sensibilidad a costos.

### D. Parameter Perturbation
Para cada estrategia variar parámetros alrededor del óptimo. Rechazar picos estrechos y preferir mesetas estables.

Ejemplos:
- lookbacks;
- thresholds;
- stop/target;
- ventanas temporales;
- filtros de volatilidad;
- pesos de confirmación.

### E. Time Perturbation
Mover entradas y ventanas en ±1, ±2, ±5, ±10 minutos para comprobar que el edge no depende de un timestamp exacto accidental.

### F. Cost / Execution Stress
Repetir con:
- comisión base;
- 1.5x costos;
- 2x costos;
- slippage normal;
- slippage adverso;
- latencia añadida.

### G. Cross-Regime / Cross-Period
Separar:
- bull;
- bear;
- range;
- high-vol;
- low-vol;
- crisis/event days;
- openings y transiciones de sesión.

### H. Cross-Instrument Robustness
Una estrategia puede ser especializada, pero debe saberse si el edge es:
- específico NQ;
- compartido NQ/ES;
- generalizable a YM/RTY;
- o dependiente de un solo instrumento.

### I. Anti-Overfitting por búsqueda combinatoria
Como se probarán muchas coaliciones, aplicar:
- CSCV / Probability of Backtest Overfitting (PBO);
- Deflated Sharpe Ratio (DSR);
- control del número total de pruebas;
- penalización por complejidad/tamaño de coalición;
- comparación contra estrategia individual base y contra benchmark nulo.

### J. Sensitivity to Strategy Membership
Para una coalición ganadora:
- quitar un miembro;
- sustituirlo por otro de la misma familia;
- agregar un miembro;
- cambiar pesos;
- medir si el rendimiento colapsa.

Si colapsa con cambios pequeños, la coalición es frágil.

## Criterio de promoción

Una coalición NO se promueve por alto win rate solamente. Debe demostrar simultáneamente:
- EV neto positivo;
- PF > 1 después de costos;
- DD tolerable;
- estabilidad OOS;
- robustez Monte Carlo;
- baja sensibilidad paramétrica;
- PBO aceptable;
- DSR aceptable;
- costos/latencia soportables;
- principio de salida coordinada consistente;
- ventaja incremental frente al mejor miembro individual.

## Ruta de promoción

IDEA -> GENERATED -> FAST_BACKTEST -> FILTERED -> VALIDATION -> OOS -> WALK_FORWARD -> MONTE_CARLO -> PARAMETER_STRESS -> COST_STRESS -> PBO/DSR -> REGIME_TEST -> PORTFOLIO_FIT -> QA -> PAPER -> SHADOW -> LIVE_LIMITED -> ACTIVE.

## Regla de seguridad

Si DATA_UNSAFE, incertidumbre excesiva, veto macro o ausencia de coalición robusta con EV positivo: NO TRADE.
