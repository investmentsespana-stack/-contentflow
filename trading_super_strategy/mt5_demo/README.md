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
