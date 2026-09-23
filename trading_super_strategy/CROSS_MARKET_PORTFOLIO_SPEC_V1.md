# Cross-Market Robot Portfolio Fit — v1

Fecha: 2026-09-22
Estado: RESEARCH / DEMO ONLY

## Objetivo

Convertir las estrategias robustas generadas por SQX/Vibe en carteras de robots que no dependan de un solo mercado ni de una sola lógica.

La unidad final de evaluación no es únicamente el robot individual. Cada robot debe demostrar:
1. edge y robustez individual;
2. aporte marginal a la cartera;
3. baja redundancia con los robots ya seleccionados;
4. drawdowns suficientemente desincronizados;
5. diversificación por mercado y familia.

## Universo inicial

El motor es dinámico, pero el universo operativo actual incluye:
- XAUUSD / GOLD;
- NQ / Nasdaq;
- ES o SP500 / S&P 500;
- DJ / Dow;
- DXY / Dollar Index;
- CL/XTIUSD cuando se incorpore petróleo.

Los alias del broker nunca sustituyen la identidad económica del mercado.

## Separación de responsabilidades

- Coalition/Synergy Engine: combina señales compatibles para una posición coordinada.
- Cross-Market Portfolio Engine: combina robots/estrategias ya robustas en mercados y lógicas diferentes para construir una cartera.
- MT5 DEMO: ejecuta la cartera aprobada en demo. LIVE permanece deshabilitado.

## Datos mínimos por robot

- strategy_id;
- market;
- family;
- timeframe;
- daily_returns o PnL normalizado;
- estado de robustez individual;
- metadatos de origen SQX/Vibe.

No se admite un robot a PORTFOLIO_FIT sin serie temporal suficiente.

## Hard gates de cartera

Un candidato se rechaza si:
- no está aprobado individualmente para research/demo;
- excede el límite de concentración por mercado;
- su correlación absoluta máxima con un miembro existente supera el umbral;
- su solapamiento de drawdown con un miembro existente supera el umbral;
- empeora el drawdown agregado más allá de la tolerancia sin compensación de diversificación;
- duplica mercado + familia + timeframe con comportamiento casi idéntico.

## Métricas obligatorias

Por robot y por cartera:
- retorno neto;
- profit factor;
- max drawdown;
- correlación de retornos;
- correlación de pérdidas;
- solapamiento de drawdown;
- contribución marginal al drawdown;
- contribución marginal al retorno;
- concentración por mercado/familia;
- leave-one-out: quitar cada robot y volver a medir;
- estabilidad por año/regímenes cuando existan datos.

## Regla de selección

No se busca la cartera con mayor beneficio histórico. Se busca una cartera robusta donde:
- los miembros tengan edge individual;
- la redundancia sea baja;
- los drawdowns no se concentren;
- ningún robot sostenga por sí solo el resultado;
- quitar un miembro no destruya la cartera;
- el resultado sobreviva OOS, walk-forward, costos y Monte Carlo.

Pesos iniciales permitidos: EQUAL y MARKET_BALANCED. No se permiten pesos optimizados por retorno en v1.

## Integración en pipeline

IDEA -> GENERATED -> FAST_BACKTEST -> FILTERED -> VALIDATION -> OOS -> WALK_FORWARD -> MONTE_CARLO -> PARAMETER_STRESS -> COST_STRESS -> PBO/DSR -> REGIME_TEST -> PORTFOLIO_FIT -> QA -> MT5_DEMO -> PAPER/SHADOW.

PORTFOLIO_FIT debe ejecutarse cada vez que un nuevo robot supera robustez. El candidato se compara contra las carteras existentes y se registra ACCEPT/REJECT con evidencia.

## Criterio de demo

La primera cartera demo objetivo puede contener hasta 10 robots, pero el número no se fuerza. Si solo 4-6 aportan diversificación real, se mantienen 4-6. Añadir robots redundantes está prohibido.

## Seguridad

- RESEARCH_ONLY=true
- DEMO_ONLY=true
- LIVE=false
- BROKER_EXECUTION_REAL=false
