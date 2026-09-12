# Coalition Backtest Search — v0.6

Fecha: 2026-09-12

## Mandato

La búsqueda de sinergias se realiza en backtesting combinando estrategias unas con otras hasta encontrar uno o varios grupos óptimos. No se presupone que exista una única coalición universal ni que una estrategia tenga la misma calidad para LONG y SHORT.

## Unidad de búsqueda

Cada estrategia se evalúa por lado y contexto. Una misma lógica puede generar dos variantes estadísticas distintas, por ejemplo `breakout_long` y `breakout_short`.

La búsqueda se particiona por:

- instrumento;
- sesión y minutos desde apertura;
- volatilidad;
- tendencia/régimen;
- estructura/liquidez;
- condiciones de flow/cross-market;
- contexto macro cuando aplique.

## Búsqueda combinatoria

Para cada partición se prueban:

1. estrategias individuales;
2. todos los pares compatibles;
3. tríos compatibles;
4. coaliciones de cuatro compatibles;
5. posteriormente tamaños mayores solo si el uplift OOS justifica la complejidad.

LONG y SHORT se buscan y rankean por separado.

Ejemplo conceptual:

- `LONG_POOL`: A+B, A+C, B+C, A+B+C, A+B+D...
- `SHORT_POOL`: E+F, E+G, F+G, E+F+G...

El grupo óptimo alcista puede ser completamente distinto del grupo óptimo bajista.

## Métricas por coalición

- win rate;
- uplift de win rate frente al mejor miembro individual;
- expectancy neta;
- profit factor;
- drawdown;
- MAE/MFE;
- duración;
- costos y slippage;
- error correlation;
- contradiction rate;
- target compatibility;
- estabilidad OOS;
- robustez walk-forward;
- PBO/CSCV;
- Deflated Sharpe Ratio.

No se promueve una coalición por win rate aislado.

## Routing en vivo/paper

El Regime Engine determina el estado actual.

- régimen alcista validado -> solo compiten coaliciones LONG aprobadas;
- régimen bajista validado -> solo compiten coaliciones SHORT aprobadas;
- lateral/rango -> NO_TRADE por política canónica v0.6;
- régimen incierto -> NO_TRADE.

Esto evita que grupos alcistas y bajistas se contradigan simultáneamente.

## Beneficio único

La coalición seleccionada genera una única posición y un único plan de beneficio/riesgo. No existen targets independientes por estrategia.

El Adaptive Exit / Probability Engine probará varios objetivos R y escogerá target, parciales, trailing y time-exit según probabilidad, volatilidad, estructura, sesión, MAE/MFE y régimen.

## Criterio de éxito

Una coalición solo se considera óptima si:

- mejora o preserva win rate y EV frente a sus miembros individuales;
- mantiene principios compatibles;
- no depende de señales redundantes;
- sobrevive OOS y walk-forward;
- no muestra sobreajuste combinatorio significativo;
- mantiene resultado después de costos y slippage;
- su ventaja es específica y reproducible para el régimen/dirección donde será activada.

## Estado

La infraestructura de selección direccional LONG/SHORT y routing bullish/bearish/sideways ya está incorporada en `StrategySynergyEngine`. El siguiente bloque es construir el backtester que alimente estas métricas con estrategias reales e historial suficiente.
