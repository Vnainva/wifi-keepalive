<#
.SYNOPSIS
    WiFi Keep-Alive Mark 2 - Installer
.DESCRIPTION
    One-command setup:
      1. Creates %LOCALAPPDATA%\WifiKeepAlive\
      2. Copies scripts into it
      3. Runs first-run config wizard (if config.json does not exist)
      4. Registers a Scheduled Task (AtLogOn, RunLevel Highest)
      5. Shows a toast notification

    Run from an elevated (Administrator) PowerShell prompt:
      powershell -ExecutionPolicy Bypass -File install.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$InstallDir  = Join-Path $env:LOCALAPPDATA 'WifiKeepAlive'
$ConfigPath  = Join-Path $InstallDir 'config.json'
$TaskName    = 'WiFiKeepAlive'
$ScriptName  = 'wifi-keepalive.ps1'
$ScriptDir   = $PSScriptRoot

# -- Check Admin --

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {
    Write-Host ''
    Write-Host '  This installer needs Administrator privileges.' -ForegroundColor Yellow
    Write-Host '  Restarting elevated...' -ForegroundColor Yellow
    Write-Host ''
    Start-Process powershell -Verb RunAs -ArgumentList `
        ('-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"')
    exit
}

# -- Banner --

Write-Host ''
Write-Host '  ======================================================' -ForegroundColor Cyan
Write-Host '   WiFi Keep-Alive Mark 2 - Installer' -ForegroundColor Cyan
Write-Host '  ======================================================' -ForegroundColor Cyan
Write-Host ''

# -- Step 1: Create install directory --

if (-not (Test-Path $InstallDir)) {
    New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
    Write-Host ('  Created: ' + $InstallDir) -ForegroundColor Green
}
else {
    Write-Host ('  Exists:  ' + $InstallDir) -ForegroundColor Gray
}

# -- Step 2: Copy scripts --

$filesToCopy = @($ScriptName, 'uninstall.ps1')
foreach ($file in $filesToCopy) {
    $src = Join-Path $ScriptDir $file
    if (-not (Test-Path $src)) {
        Write-Host ('  ERROR: Cannot find ' + $src) -ForegroundColor Red
        Write-Host ('  Make sure ' + $file + ' is in the same folder as install.ps1') -ForegroundColor Red
        pause
        exit 1
    }
    Copy-Item -Path $src -Destination (Join-Path $InstallDir $file) -Force
    Write-Host ('  Copied:  ' + $file + ' -> ' + $InstallDir) -ForegroundColor Green
}

# -- Step 3: First-run config wizard --

if (-not (Test-Path $ConfigPath)) {
    Write-Host ''
    Write-Host '  -- First-Run Configuration --' -ForegroundColor Yellow
    Write-Host ''

    # Auto-detect default gateway
    $detectedGateway = $null
    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($route) {
            $detectedGateway = $route.NextHop
        }
    }
    catch {}

    # Auto-detect current SSID
    $detectedSSID = $null
    try {
        $wlanOutput = netsh wlan show interfaces 2>$null
        foreach ($line in $wlanOutput) {
            if ($line -match '^\s+SSID\s+:\s+(.+)$' -and $line -notmatch 'BSSID') {
                $detectedSSID = $Matches[1].Trim()
                break
            }
        }
    }
    catch {}

    # Gateway
    $defaultGw = 'http://10.17.0.1:1000'
    if ($detectedGateway) {
        $defaultGw = 'http://' + $detectedGateway + ':1000'
    }
    Write-Host ('  Gateway URL (detected: ' + $defaultGw + ')') -ForegroundColor White
    $gwInput = Read-Host '    Press Enter to accept, or type a different URL'
    $gateway = if ([string]::IsNullOrWhiteSpace($gwInput)) { $defaultGw } else { $gwInput.Trim() }

    # Username
    $username = Read-Host '  Username'
    while ([string]::IsNullOrWhiteSpace($username)) {
        Write-Host '    Username cannot be empty.' -ForegroundColor Red
        $username = Read-Host '  Username'
    }

    # Password
    $password = Read-Host '  Password'
    while ([string]::IsNullOrWhiteSpace($password)) {
        Write-Host '    Password cannot be empty.' -ForegroundColor Red
        $password = Read-Host '  Password'
    }

    # SSID
    $defaultSSID = if ($detectedSSID) { $detectedSSID } else { 'CollegeWiFi' }
    Write-Host ('  Target WiFi SSID (detected: ' + $defaultSSID + ')') -ForegroundColor White
    $ssidInput = Read-Host '    Press Enter to accept, or type a different SSID'
    $targetSSID = if ([string]::IsNullOrWhiteSpace($ssidInput)) { $defaultSSID } else { $ssidInput.Trim() }

    # Check interval
    $intervalInput = Read-Host '  Check interval in seconds (default: 150)'
    $checkInterval = if ([string]::IsNullOrWhiteSpace($intervalInput)) { 150 } else { [int]$intervalInput }

    # Save config
    $config = @{
        gateway              = $gateway
        username             = $username
        password             = $password
        targetSSID           = $targetSSID
        checkIntervalSeconds = $checkInterval
    }
    $config | ConvertTo-Json -Depth 2 | Set-Content -Path $ConfigPath -Encoding UTF8
    Write-Host ''
    Write-Host ('  Config saved to: ' + $ConfigPath) -ForegroundColor Green
}
else {
    Write-Host ('  Config:  ' + $ConfigPath + ' (already exists, keeping)') -ForegroundColor Gray
}

# -- Step 4: Register Scheduled Task --

Write-Host ''
Write-Host '  Registering Scheduled Task...' -ForegroundColor Cyan

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$scriptPath = Join-Path $InstallDir $ScriptName

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument ('-WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $scriptPath + '"')

$trigger = New-ScheduledTaskTrigger -AtLogOn

$settings = New-ScheduledTaskSettingsSet `
    -Hidden `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Days 365)

try {
    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -RunLevel Highest `
        -Description 'WiFi Keep-Alive: auto re-authenticates to FortiGate captive portal.' `
        -Force | Out-Null

    Write-Host '  Scheduled task registered!' -ForegroundColor Green
    Write-Host ('    Task name:   ' + $TaskName) -ForegroundColor White
    Write-Host '    Trigger:     At logon' -ForegroundColor White
    Write-Host '    Run level:   Highest (elevated)' -ForegroundColor White
    Write-Host ('    Script:      ' + $scriptPath) -ForegroundColor White
}
catch {
    Write-Host ('  ERROR: Failed to register task: ' + $_) -ForegroundColor Red
    Write-Host '  The script is installed but will not auto-start.' -ForegroundColor Yellow
}

# -- Step 5: Toast notification --

try {
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]

    $xml = [Windows.Data.Xml.Dom.XmlDocument]::new()
    $toastStr = '<toast><visual><binding template="ToastGeneric">'
    $toastStr += '<text>WiFi Keep-Alive Installed</text>'
    $toastStr += '<text>Auto-login is active. It will start automatically at your next login.</text>'
    $toastStr += '</binding></visual></toast>'
    $xml.LoadXml($toastStr)
    $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
    $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('WifiKeepAlive')
    $notifier.Show($toast)
}
catch {
    Write-Host '  (Toast notification unavailable on this system)' -ForegroundColor Yellow
}

# -- Step 6: Offer to start now --

Write-Host ''
$startNow = Read-Host '  Start WiFi Keep-Alive now? (y/n)'
if ($startNow -eq 'y' -or $startNow -eq 'Y') {
    Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host '  Started! WiFi Keep-Alive is now running in the background.' -ForegroundColor Green
}

Write-Host ''
Write-Host '  Installation complete.' -ForegroundColor Green
$uninstallPath = Join-Path $InstallDir 'uninstall.ps1'
Write-Host ('  Config:    ' + $ConfigPath) -ForegroundColor White
Write-Host ('  Scripts:   ' + $InstallDir) -ForegroundColor White
Write-Host ('  Uninstall: ' + $uninstallPath) -ForegroundColor White
Write-Host ''
pause
