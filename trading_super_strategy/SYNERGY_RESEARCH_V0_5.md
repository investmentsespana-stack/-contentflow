# Strategy Synergy Research — v0.5

Fecha: 2026-09-12

## Mandato

La Super Estrategia no ejecuta bots independientes. Construye una coalición dinámica de estrategias compatibles y genera un único Position Plan coordinado: una dirección, un riesgo agregado y una política de salida/target común.

## Hallazgos de investigación incorporados

1. Mixture-of-Experts y selección dinámica por régimen: la literatura reciente en finanzas muestra valor en asignar pesos/seleccionar expertos según el estado del mercado en lugar de fijar un experto universal.
2. Diversidad + precisión: una coalición útil necesita expertos con edge individual y errores suficientemente diversos; baja diversidad puede convertir varios votos en la misma señal duplicada.
3. Régimen y volatilidad importan: la compatibilidad debe estimarse condicionalmente por sesión, minutos desde apertura, volatilidad, estructura y régimen, no únicamente en toda la muestra agregada.
4. Salidas adaptativas: profit target, stop y time-exit deben probarse conjuntamente y escalarse por volatilidad/contexto. Ratios negativos son candidatos válidos si conservan EV positivo después de costos.
5. Anti-overfitting obligatorio: la búsqueda combinatoria multiplica el número de pruebas; por ello toda coalición candidata debe pasar OOS/walk-forward y controles de multiple testing (CSCV/PBO y Deflated Sharpe Ratio).

## Compatibilidad dura (hard gates)

Una coalición se rechaza si ocurre cualquiera de estos casos:

- estrategias activas apuntan a direcciones opuestas;
- una condición de entrada de una estrategia constituye invalidación explícita de otra;
- la tasa histórica de contradicción condicional excede el umbral;
- los errores son tan correlacionados que las estrategias son redundantes;
- los horizontes/targets son incompatibles y no admiten un Position Plan único;
- faltan métricas históricas de compatibilidad;
- DATA_UNSAFE o veto macro/fundamental.

## Búsqueda combinatoria

Para cada contexto (instrumento × sesión/apertura × volatilidad × régimen × estructura):

- evaluar estrategias individuales;
- generar pares, tríos y coaliciones pequeñas;
- medir win-rate de la coalición y uplift vs mejor miembro individual;
- expectancy neta, profit factor, drawdown, MAE/MFE, duración, costos/slippage;
- correlación de errores y contradiction rate;
- target overlap / compatibilidad de horizonte;
- estabilidad OOS y walk-forward;
- PBO/CSCV y DSR después de contabilizar el número de pruebas.

El ranking no maximiza win-rate aislado. Busca la mejor combinación robusta de win-rate + EV + estabilidad + diversidad - drawdown - costos - contradicción - sobreajuste.

## Beneficio único / Coordinated Target

Las estrategias no envían órdenes ni targets separados. La coalición produce evidencia; el Probability/Exit Engine produce un único Position Plan.

Para cada entrada candidata se estiman probabilidades de alcanzar varios targets antes del stop, por ejemplo 0.25R, 0.50R, 0.75R, 1R, 1.5R, 2R, 3R y 4R. Se permite ratio riesgo/beneficio negativo cuando el EV neto es positivo y supera los filtros de robustez.

El target final puede ser único o una política de parciales/trailing, pero siempre pertenece a la posición agregada, nunca a estrategias independientes compitiendo entre sí.

## Hipótesis prioritarias a probar

- Liquidity Sweep + Order Flow + Cross-Market Confirmation.
- Breakout + Order Flow + Momentum, solo en régimen expansivo.
- Mean Reversion + VWAP + Liquidity/Absorption, solo en rango/baja volatilidad.
- Opening Drive + Order Flow + Cross-Market, condicionado a minutos desde apertura.
- Continuation/Trend + Pullback + Volume/Order Flow.
- Event Reaction + Technical Structure + Cross-Market, con macro como modificador/veto.

Estas son familias de búsqueda, no afirmaciones de rentabilidad. El backtest decidirá cuáles sobreviven.

## Estado de implementación

- StrategySynergyEngine v0.1 agregado.
- Hard gates de dirección, principio, redundancia, contradicción y target overlap agregados.
- Búsqueda de mejor coalición pequeña agregada.
- Target coordinado inicial se entrega solo como seed; el target final requiere Probability/Exit Engine.
- Live money permanece OFF.
