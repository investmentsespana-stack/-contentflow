# Published Strategy-Group Seeds — v0.6

Fecha: 2026-09-12

## Propósito

Usar grupos y arquitecturas publicadas como semillas de búsqueda para el backtesting combinatorio. Ningún resultado externo se considera validado para nuestro sistema hasta reproducirlo con datos propios, costos, OOS, walk-forward y controles anti-overfit.

## Semillas publicadas para probar

### 1) Mean-Reversion 5-Signal Ensemble
Fuente pública: QuantEngines, 2026.
Componentes divulgados: Z-Score + Volume Profile + RSI Extremes + Order Flow + Volatility Mean Reversion.
Resultados publicados: 5-signal ensemble 64.3% win rate / PF 2.18 / 589 trades; ML-filtered version 71.2% WR / PF 2.87 / 412 trades.
Uso en nuestro sistema: semilla MR_HIGH_WIN. Separar LONG y SHORT, filtrar por volatilidad/sesión y probar abstención.

### 2) Intraday Capitulation Long Ensemble — ES/NQ
Fuente pública: r/algotrading, 2026. Autorreporte comunitario, no auditado.
Descripción divulgada: 4-5 condiciones técnicas simultáneas, 15m, long-only, RTH, next-bar entry, stop 0.30%, target 0.75%.
Resultados publicados OOS 2019-2026: ES 67.8% WR / PF 5.29 / 146 trades; NQ 64.2% WR / PF 5.29 / 137 trades.
Uso: semilla LONG_CAPITULATION. La señal exacta no está publicada, así que no copiar; construir familias equivalentes y dejar que nuestro buscador descubra combinaciones.

### 3) NQ/MNQ 12-Model Ensemble
Fuente pública: GitHub s-k-28/nq-es-trader-5k-payout.
Arquitectura: 8 modelos mean-reversion + 4 momentum; priority resolver selecciona como máximo una posición; filtros de calidad, cooldown, riesgo adaptativo y walk-forward.
Resultados publicados: 2,716 trades, 44.6% WR, expectancy +0.238R, PF 1.66, max DD -12.6R.
Uso: semilla HYBRID_MR_MOMENTUM y evidencia de que el mejor grupo no tiene que maximizar WR si EV/PF son mejores.

### 4) Dynamic Mean-Reversion + Momentum
Fuente académica: James Velissaris, Diversified Statistical Arbitrage, SSRN.
Arquitectura: combinación dinámica de mean reversion y momentum con rebalanceo según entorno de mercado; reporta resultados risk-adjusted fuertes tanto en mercado bajista 2008 como alcista 2009.
Uso: semilla HYBRID_REGIME_SWITCH, no como confirmación simultánea obligatoria sino como expertos que pueden dominar en regímenes diferentes.

### 5) Mixture-of-Experts / Dynamic Router
Fuentes académicas: AlphaMix (Sun, Wang, An, 2022) y ensemble PPO/A2C/SAC (Li et al., 2022).
Arquitectura: múltiples expertos independientes + router/selector según incertidumbre o desempeño/contexto. El ensemble PPO/A2C/SAC reporta 71.92% cumulative return, Sharpe 1.41 y max drawdown -9.5%, mejores métricas de estabilidad que los agentes individuales aunque no publica win rate.
Uso: el Coalition Router debe escoger el grupo según régimen en lugar de forzar todos los expertos a votar siempre.

### 6) Bull/Bear Specialized Experts
Fuente académica reciente: Luo & Mulvey, Princeton/SSRN, 2026.
Arquitectura: Mixture-of-Experts con agentes Bull y Bear separados, action masking por régimen y reward riesgo/retorno.
Uso: refuerza nuestra búsqueda separada de LONG coalition y SHORT coalition. Un grupo puede ser excelente solo comprando y otro solo vendiendo.

### 7) Commercial Mean-Reversion Benchmark
Fuente pública/comercial: Aeromir Phoenix.
Resultados publicados: NQ 69.8% WR sobre 2,626 trades; ES 64.2% WR sobre 2,197 trades; PF 1.30; walk-forward/Monte Carlo declarados.
Uso: benchmark externo de plausibilidad, no evidencia independiente ni semilla de reglas porque la lógica es propietaria.

## Cómo se aplican estas semillas

El buscador NO copiará un grupo externo como producto final. Para cada familia generará variantes y combinaciones, separadas por:
- dirección: LONG / SHORT;
- instrumento: NQ / ES / YM / RTY;
- sesión y minutos desde apertura;
- volatilidad;
- régimen: trend-up / trend-down / range / transition / shock;
- estructura y liquidez;
- order flow / volume;
- cross-market;
- macro event risk.

Se probarán estrategias individuales, pares, tríos y coaliciones pequeñas. El ranking medirá WR, uplift de WR vs mejor miembro individual, expectancy neta, PF, DD, MAE/MFE, costos, error correlation, contradiction rate y estabilidad OOS.

## Regla operativa objetivo

- Bullish regime robusto -> buscar y activar mejor LONG coalition.
- Bearish regime robusto -> buscar y activar mejor SHORT coalition.
- Lateral/uncertain o sin edge OOS -> NO TRADE.
- El target/stop es único y coordinado para la posición agregada.
- Ratio negativo, 1:1 o positivo se elige por EV neto condicionado al contexto.

## Validación obligatoria

Train -> Validation -> OOS -> Walk-Forward -> Monte Carlo -> parameter perturbation -> CSCV/PBO -> Deflated Sharpe -> paper -> shadow.

Live money permanece OFF hasta promoción explícita.