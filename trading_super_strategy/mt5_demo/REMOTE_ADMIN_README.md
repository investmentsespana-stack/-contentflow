# StrategyQuant Custom Project reader + VPS remote admin recovery

## Offline Custom Project reader

This is read-only. It opens a StrategyQuant `.cfx` file and reports:

- task order
- Build / Retest / Monte Carlo / OOS / slippage / loop signals
- symbols/timeframes referenced by each task
- embedded resources/instruments
- databanks

Usage:

```powershell
python trading_super_strategy\sqx_tools\inspect_custom_project.py project.cfx
```

JSON:

```powershell
python trading_super_strategy\sqx_tools\inspect_custom_project.py project.cfx --json
```

## Windows VPS remote admin repair

`Repair-CygnusRemoteAdmin.ps1` does not change passwords or broker settings.

It:
- ensures WinRM service is running;
- starts any existing GitHub Actions runner service;
- optionally enables Windows OpenSSH and TCP/22 firewall rule.

Run as Administrator:

```powershell
powershell -ExecutionPolicy Bypass -File .\Repair-CygnusRemoteAdmin.ps1 -EnableOpenSSH
```

After this, the governed deployment workflows can install the MT5 demo multiterminal and deploy the latest SQX bridge.
