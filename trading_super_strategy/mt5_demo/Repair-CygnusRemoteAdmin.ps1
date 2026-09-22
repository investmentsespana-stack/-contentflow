param(
    [switch]$EnableOpenSSH
)

$ErrorActionPreference = 'Stop'

function Write-State([string]$Name, [string]$Value) {
    Write-Output ("{0}={1}" -f $Name, $Value)
}

Write-State 'COMPUTERNAME' $env:COMPUTERNAME

# WinRM: keep the existing authentication policy; only ensure the service/listener are available.
Set-Service -Name WinRM -StartupType Automatic
Start-Service -Name WinRM
try {
    Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
} catch {
    Write-State 'WINRM_ENABLE_WARNING' $_.Exception.Message
}
$winrm = Get-Service WinRM
Write-State 'WINRM_STATUS' $winrm.Status
Write-State 'WINRM_STARTTYPE' $winrm.StartType

# GitHub self-hosted runner: start any installed Actions runner service without changing registration.
$runnerServices = Get-Service -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'actions.runner.*' -or $_.DisplayName -like 'GitHub Actions Runner*' }

if($runnerServices) {
    foreach($svc in $runnerServices) {
        try {
            Set-Service -Name $svc.Name -StartupType Automatic
            if($svc.Status -ne 'Running') { Start-Service -Name $svc.Name }
            $fresh = Get-Service -Name $svc.Name
            Write-State ("RUNNER_" + $svc.Name) $fresh.Status
        } catch {
            Write-State ("RUNNER_" + $svc.Name + "_ERROR") $_.Exception.Message
        }
    }
} else {
    Write-State 'RUNNER_SERVICE' 'NOT_FOUND'
}

# Optional OpenSSH recovery. Never installs third-party software; only enables Windows capability if present/available.
if($EnableOpenSSH) {
    $cap = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue
    if($cap -and $cap.State -ne 'Installed') {
        Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
    }
    if(Get-Service sshd -ErrorAction SilentlyContinue) {
        Set-Service -Name sshd -StartupType Automatic
        Start-Service -Name sshd
        if(-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
        } else {
            Enable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' | Out-Null
        }
        Write-State 'SSHD_STATUS' (Get-Service sshd).Status
    } else {
        Write-State 'SSHD_STATUS' 'NOT_AVAILABLE'
    }
}

Write-State 'REMOTE_ADMIN_REPAIR' 'PASS'
