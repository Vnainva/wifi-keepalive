<#
.SYNOPSIS
    WiFi Keep-Alive Mark 2 - Uninstaller
.DESCRIPTION
    Cleanly removes WiFi Keep-Alive:
      1. Kills any running instance
      2. Unregisters the Scheduled Task
      3. Deletes the install directory (prompts before removing config.json)

    Run from an elevated (Administrator) PowerShell prompt:
      powershell -ExecutionPolicy Bypass -File uninstall.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$InstallDir = Join-Path $env:LOCALAPPDATA 'WifiKeepAlive'
$ConfigPath = Join-Path $InstallDir 'config.json'
$TaskName   = 'WiFiKeepAlive'

# -- Check Admin --
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {
    Write-Host ''
    Write-Host '  This uninstaller needs Administrator privileges.' -ForegroundColor Yellow
    Write-Host '  Restarting elevated...' -ForegroundColor Yellow
    Write-Host ''
    Start-Process powershell -Verb RunAs -ArgumentList `
        ('-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"')
    exit
}

Write-Host ''
Write-Host '  ======================================================' -ForegroundColor Cyan
Write-Host '   WiFi Keep-Alive Mark 2 - Uninstaller' -ForegroundColor Cyan
Write-Host '  ======================================================' -ForegroundColor Cyan
Write-Host ''

# -- Step 1: Kill any running instance --
Write-Host '  Stopping running instances...' -ForegroundColor Cyan
$killed = $false
Get-Process powershell*, pwsh* -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        $cmdLine = (Get-CimInstance Win32_Process -Filter ('ProcessId=' + $_.Id) -ErrorAction SilentlyContinue).CommandLine
        if ($cmdLine -and $cmdLine -like '*wifi-keepalive*') {
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
            Write-Host ('    Stopped PID ' + $_.Id) -ForegroundColor Yellow
            $killed = $true
        }
    }
    catch {}
}
if (-not $killed) {
    Write-Host '    No running instances found.' -ForegroundColor Gray
}

# -- Step 2: Remove Scheduled Task --
Write-Host '  Removing Scheduled Task...' -ForegroundColor Cyan
try {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host ('    Task removed: ' + $TaskName) -ForegroundColor Green
    }
    else {
        Write-Host ('    Task not found: ' + $TaskName + ' (already removed)') -ForegroundColor Gray
    }
}
catch {
    Write-Host ('    Warning: ' + $_) -ForegroundColor Yellow
}

# -- Step 3: Remove install directory --
Write-Host '  Removing install files...' -ForegroundColor Cyan

if (Test-Path $InstallDir) {
    # Prompt before deleting config (contains credentials)
    if (Test-Path $ConfigPath) {
        Write-Host ''
        Write-Host '  config.json contains your saved credentials.' -ForegroundColor Yellow
        $deleteConfig = Read-Host '  Delete config.json too? (y/n)'
        if ($deleteConfig -ne 'y' -and $deleteConfig -ne 'Y') {
            $backupPath = Join-Path $env:LOCALAPPDATA 'WifiKeepAlive_config_backup.json'
            Copy-Item -Path $ConfigPath -Destination $backupPath -Force
            Write-Host ('    Config backed up to: ' + $backupPath) -ForegroundColor Green
        }
    }

    try {
        Remove-Item -Path $InstallDir -Recurse -Force
        Write-Host ('    Removed: ' + $InstallDir) -ForegroundColor Green
    }
    catch {
        Write-Host ('    Warning: Could not fully remove ' + $InstallDir) -ForegroundColor Yellow
        Write-Host '    You may need to delete it manually.' -ForegroundColor Yellow
    }
}
else {
    Write-Host ('    ' + $InstallDir + ' not found (already removed).') -ForegroundColor Gray
}

# -- Also clean up old Mark 1 startup entry if it exists --
$oldStartupVbs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\wifi_keepalive.vbs'
if (Test-Path $oldStartupVbs) {
    Remove-Item $oldStartupVbs -Force -ErrorAction SilentlyContinue
    Write-Host '    Removed old Mark 1 startup entry (wifi_keepalive.vbs).' -ForegroundColor Green
}

Write-Host ''
Write-Host '  Uninstall complete.' -ForegroundColor Green
Write-Host ''
pause
