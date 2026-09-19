# Cygnus Vibe-Trading VPS Research Integration

Purpose: install Vibe-Trading beside StrategyQuant on the Windows VPS as an independent research/certification layer.

## Fixed safety contract

- Research only.
- No broker credentials during installation.
- No live-money profile.
- HTTP API bound to 127.0.0.1:8899.
- MCP bound to 127.0.0.1:8900/mcp.
- MCP shell tools disabled.
- State isolated under C:\\Cygnus\\VibeTrading.
- StrategyQuant is not modified or stopped.
- Local/frozen datasets are preferred for cross-validation of SQX candidates.

## Install

Run PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install_vibe_trading_research.ps1
```

The installer uses an existing Python 3.11+ if present. If Python is missing and winget is available, it installs Python 3.11 for the current Windows user, creates an isolated venv, pins `vibe-trading-ai==0.1.15`, and writes start/stop/verify scripts under `C:\Cygnus\VibeTrading`.

## Start

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Cygnus\VibeTrading\Start-VibeResearch.ps1
```

## Verify

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Cygnus\VibeTrading\Verify-VibeResearch.ps1
```

## Stop

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Cygnus\VibeTrading\Stop-VibeResearch.ps1
```

The next integration step is Director/RARA discovery against the local MCP endpoint, then cross-validation of the frozen six NQ CFD strategies. No live execution is permitted in this phase.
