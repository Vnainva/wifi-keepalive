<#
.SYNOPSIS
    WiFi Keep-Alive - One-Command Web Installer
.DESCRIPTION
    Downloads and installs WiFi Keep-Alive from GitHub with a single command:

      irm https://raw.githubusercontent.com/Vnainva/wifi-keepalive/main/web-install.ps1 | iex

    This script:
      1. Downloads wifi-keepalive.ps1 and uninstall.ps1 from GitHub
      2. Runs the first-run config wizard
      3. Registers a Scheduled Task for auto-start
      4. Starts the script immediately
#>

$ErrorActionPreference = 'Stop'
$RepoBase = 'https://raw.githubusercontent.com/Vnainva/wifi-keepalive/main'
$InstallDir = Join-Path $env:LOCALAPPDATA 'WifiKeepAlive'
$ConfigPath = Join-Path $InstallDir 'config.json'
$TaskName = 'WiFiKeepAlive'

# -- Check Admin --
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    Write-Host ''
    Write-Host '  This installer needs Administrator privileges.' -ForegroundColor Yellow
    Write-Host '  Saving installer and restarting elevated...' -ForegroundColor Yellow
    Write-Host ''
    $tempScript = Join-Path $env:TEMP 'wifi-keepalive-install.ps1'
    Invoke-WebRequest -Uri ($RepoBase + '/web-install.ps1') -OutFile $tempScript -UseBasicParsing
    Start-Process powershell -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $tempScript + '"')
    return
}

# -- Banner --
Write-Host ''
Write-Host '  ======================================================' -ForegroundColor Cyan
Write-Host '   WiFi Keep-Alive - One-Command Installer' -ForegroundColor Cyan
Write-Host '  ======================================================' -ForegroundColor Cyan
Write-Host ''

# -- Step 1: Create install directory --
if (-not (Test-Path $InstallDir)) {
    New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
}
Write-Host ('  Install dir: ' + $InstallDir) -ForegroundColor Green

# -- Step 2: Download scripts from GitHub --
$files = @('wifi-keepalive.ps1', 'uninstall.ps1')
foreach ($file in $files) {
    $url = $RepoBase + '/' + $file
    $dest = Join-Path $InstallDir $file
    Write-Host ('  Downloading ' + $file + '...') -NoNewline
    try {
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
        Write-Host ' OK' -ForegroundColor Green
    }
    catch {
        Write-Host ' FAILED' -ForegroundColor Red
        Write-Host ('    ' + $_) -ForegroundColor Red
        Write-Host ''
        Write-Host '  Installation failed. Check your internet connection.' -ForegroundColor Red
        pause
        return
    }
}

# -- Step 3: First-run config wizard --
if (-not (Test-Path $ConfigPath)) {
    Write-Host ''
    Write-Host '  -- Setup --' -ForegroundColor Yellow
    Write-Host ''

    # Auto-detect default gateway
    $detectedGateway = $null
    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($route) { $detectedGateway = $route.NextHop }
    } catch {}

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
    } catch {}

    # Gateway
    $defaultGw = 'http://10.17.0.1:1000'
    if ($detectedGateway) { $defaultGw = 'http://' + $detectedGateway + ':1000' }
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
    Write-Host ('  Config saved!') -ForegroundColor Green
}
else {
    Write-Host ('  Config already exists, keeping it.') -ForegroundColor Gray
}

# -- Step 4: Register Scheduled Task --
Write-Host ''
Write-Host '  Registering auto-start...' -ForegroundColor Cyan

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$scriptPath = Join-Path $InstallDir 'wifi-keepalive.ps1'

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
    Write-Host '  Auto-start registered!' -ForegroundColor Green
}
catch {
    Write-Host ('  Warning: Could not register auto-start: ' + $_) -ForegroundColor Yellow
}

# -- Step 5: Start now --
Write-Host ''
Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

# -- Step 6: Toast --
try {
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]
    $xml = [Windows.Data.Xml.Dom.XmlDocument]::new()
    $toastStr = '<toast><visual><binding template="ToastGeneric">'
    $toastStr += '<text>WiFi Keep-Alive Installed!</text>'
    $toastStr += '<text>Your WiFi will stay connected forever now.</text>'
    $toastStr += '</binding></visual></toast>'
    $xml.LoadXml($toastStr)
    $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
    $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('WifiKeepAlive')
    $notifier.Show($toast)
} catch {}

# -- Done --
Write-Host '  ======================================================' -ForegroundColor Green
Write-Host '   DONE! WiFi Keep-Alive is installed and running.' -ForegroundColor Green
Write-Host '  ======================================================' -ForegroundColor Green
Write-Host ''
Write-Host '  It will auto-login whenever your college WiFi kicks you.' -ForegroundColor White
Write-Host '  Starts automatically at every login. Zero maintenance.' -ForegroundColor White
Write-Host ''
Write-Host '  Uninstall anytime:' -ForegroundColor Gray
Write-Host ('    powershell -ExecutionPolicy Bypass -File "' + (Join-Path $InstallDir 'uninstall.ps1') + '"') -ForegroundColor Gray
Write-Host ''
pause
