# Super Estrategia Adaptativa — Estado v0.5

Fecha: 2026-09-12

## Cambio de arquitectura aprobado

- La ventana NY 09:00-12:00 deja de ser restricción obligatoria y pasa a hipótesis/contexto de investigación.
- El sistema queda orientado a operación conectada 24x5 en research/paper, decidiendo cuándo existe edge según sesión, minutos desde apertura, volatilidad, estructura, liquidez, flow, cross-market y macro.
- Aperturas de sesión reciben énfasis explícito como eventos contextuales.
- El ratio riesgo/beneficio es adaptativo; se permiten ratios negativos si el EV neto y la robustez lo justifican.
- El pool deja de concebirse como estrategias independientes: se introduce Strategy Synergy / Coalition Engine.

## Ejecutado

- Databento API + GLBX.MDP3 autenticados.
- Datos reales NQ/ES/YM/RTY funcionando.
- Estudio preliminar de 15 sesiones NY ejecutado y conservado solo como investigación inicial.
- ConfirmationEngine generalizado a contexto/régimen en vez de NY fijo.
- StrategySynergyEngine agregado con hard gates de:
  - dirección;
  - compatibilidad de principios;
  - correlación de errores/redundancia;
  - contradicción;
  - compatibilidad de targets.
- Búsqueda de coaliciones pequeñas (pares/tríos/cuádruples) agregada.
- Configuración canónica v0.5 actualizada.
- CI ampliado para todos los tests del módulo trading.
- Live money sigue OFF.

## Próximo bloque crítico

1. Strategy Registry con familias, metadatos, régimen, horizonte y lógica de invalidación.
2. Generar/ingresar primeras estrategias reales por familia.
3. Backtester de coaliciones que calcule win-rate uplift, EV, PF, DD, MAE/MFE, costos, contradiction rate y error correlation por contexto.
4. Time/Session Discovery Engine y Session Open Engine.
5. Adaptive Exit / Probability Engine para target coordinado y ratios dinámicos.
6. OOS / Walk-Forward / CSCV-PBO / DSR para controlar sobreajuste combinatorio.
7. MBP-1/trades para order-flow real.
8. Paper/Shadow antes de cualquier live.
