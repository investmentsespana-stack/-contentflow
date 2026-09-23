# MT5 demo multiterminal — simple

Objetivo: preparar varias instalaciones independientes de MetaTrader 5 en la VPS para probar robots en cuentas **DEMO**.

## Qué hace

El script crea por defecto:

- `C:\Trading\MT5-DEMO-01`
- `C:\Trading\MT5-DEMO-02`
- `C:\Trading\MT5-DEMO-03`

También crea un acceso directo para cada terminal usando `/portable` y un archivo:

`C:\Trading\ABRIR-TODOS-DEMO.cmd`

para abrirlas todas.

## Uso

1. Instala MetaTrader 5 una sola vez en la VPS.
2. Cierra MetaTrader 5.
3. Ejecuta PowerShell como usuario normal.
4. Ejecuta:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup_mt5_demo.ps1
```

5. Abre cada acceso directo `MT5-DEMO-01`, `02`, `03`.
6. Inicia sesión en una **cuenta demo diferente** en cada terminal.
7. Instala/asigna los robots correspondientes.

No guarda contraseñas, no configura cuentas reales y no activa operaciones reales.

## Asignación de carteras y validación

La validación operativa queda fijada así:

- `MT5-DEMO-01` -> **Cartera A**
- `MT5-DEMO-02` -> **Cartera B**
- `MT5-DEMO-03` -> **Cartera C / futuras estrategias validadas**

Cada cartera entra únicamente después de completar el flujo:
`SQX Custom Project -> OOS -> mercados/timeframes -> slippage -> Monte Carlo -> Final -> Vibe/IA -> EA -> MT5 DEMO`.

Una vez cargada una cartera se congela durante **30 días calendario**: no se cambian parámetros para perseguir el resultado del demo. Se registran operaciones, PF, win rate, drawdown, slippage/spread, errores Expert/Journal, órdenes omitidas/duplicadas y diferencias frente al modelo SQX. El objetivo es validar ejecución y deriva modelo-demo, no optimizar sobre la marcha.

**DEMO ONLY / LIVE MONEY OFF** permanece como guardrail canónico hasta una autorización posterior y explícita.

