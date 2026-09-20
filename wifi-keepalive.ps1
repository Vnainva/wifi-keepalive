<#
.SYNOPSIS
    WiFi Keep-Alive Mark 2 - FortiGate Captive Portal Auto-Login
.DESCRIPTION
    Monitors WiFi connectivity and automatically re-authenticates to a
    FortiGate captive portal when the session expires. Pure PowerShell,
    no external dependencies.

    Config lives at: %LOCALAPPDATA%\WifiKeepAlive\config.json
    Install via:     install.ps1
.PARAMETER RunOnce
    Perform a single connectivity check and login attempt, then exit.
    Useful for debugging.
#>

[CmdletBinding()]
param(
    [switch]$RunOnce
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# -----------------------------------------------------------
#  PATHS & CONSTANTS
# -----------------------------------------------------------

$InstallDir       = Join-Path $env:LOCALAPPDATA 'WifiKeepAlive'
$ConfigPath       = Join-Path $InstallDir 'config.json'
$DebugLogPath     = Join-Path $InstallDir 'debug.log'
$MaxDebugLogBytes = 5 * 1024 * 1024   # 5 MB cap

$MutexName        = 'Global\WifiKeepAliveMutex'
$AppId            = 'WifiKeepAlive'

$NcsiUrl          = 'http://www.msftconnecttest.com/connecttest.txt'
$NcsiExpected     = 'Microsoft Connect Test'

$BrowserHeaders   = @{
    'User-Agent'      = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36'
    'Accept'          = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
    'Accept-Language' = 'en-US,en;q=0.5'
}

# Boot tolerance: for the first N seconds after start, use a shorter
# check interval so we respond quickly once WiFi comes up.
$BootGracePeriodSeconds   = 180   # 3 minutes
$BootCheckIntervalSeconds = 20    # check every 20s during grace period

$MaxFastRetries = 3

# -----------------------------------------------------------
#  SINGLE-INSTANCE GUARD (Named Mutex)
# -----------------------------------------------------------

$script:createdNew = $false
$script:mutex = New-Object System.Threading.Mutex($true, $MutexName, [ref]$script:createdNew)

if (-not $script:createdNew) {
    # Another instance is already running
    Write-Host 'Another instance of WiFi Keep-Alive is already running. Exiting.'
    $script:mutex.Dispose()
    exit 0
}

# -----------------------------------------------------------
#  LOGGING
# -----------------------------------------------------------

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG')][string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"

    # Always write to verbose stream (visible with -Verbose flag)
    Write-Verbose $line

    # Write to debug log if -Verbose was passed
    if ($VerbosePreference -eq 'Continue') {
        try {
            # Rotate if over size cap
            if (Test-Path $DebugLogPath) {
                $logSize = (Get-Item $DebugLogPath).Length
                if ($logSize -gt $MaxDebugLogBytes) {
                    $backupPath = $DebugLogPath + '.old'
                    if (Test-Path $backupPath) { Remove-Item $backupPath -Force }
                    Rename-Item $DebugLogPath $backupPath -Force
                }
            }
            Add-Content -Path $DebugLogPath -Value $line -Encoding UTF8
        }
        catch {
            # Logging must never crash the script
        }
    }
}

# -----------------------------------------------------------
#  TOAST NOTIFICATIONS
# -----------------------------------------------------------

function Show-Toast {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Body
    )
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]

        $safeTitle = [System.Security.SecurityElement]::Escape($Title)
        $safeBody  = [System.Security.SecurityElement]::Escape($Body)
        $xmlStr = '<toast><visual><binding template="ToastGeneric"><text>' + $safeTitle + '</text><text>' + $safeBody + '</text></binding></visual></toast>'

        $xml = [Windows.Data.Xml.Dom.XmlDocument]::new()
        $xml.LoadXml($xmlStr)
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId)
        $notifier.Show($toast)
        Write-Log ('Toast shown: ' + $Title) -Level DEBUG
    }
    catch {
        # Toast failure is non-critical; try BalloonTip fallback
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
            $notify = [System.Windows.Forms.NotifyIcon]::new()
            $notify.Icon = [System.Drawing.SystemIcons]::Information
            $notify.BalloonTipTitle = $Title
            $notify.BalloonTipText = $Body
            $notify.Visible = $true
            $notify.ShowBalloonTip(5000)
            Start-Sleep -Seconds 6
            $notify.Dispose()
        }
        catch {
            Write-Log ('Toast notification failed: ' + $_) -Level WARN
        }
    }
}

# -----------------------------------------------------------
#  CONFIG LOADING
# -----------------------------------------------------------

function Get-Config {
    if (-not (Test-Path $ConfigPath)) {
        Write-Host ('ERROR: Config file not found at ' + $ConfigPath) -ForegroundColor Red
        Write-Host 'Run install.ps1 first to create the configuration.' -ForegroundColor Yellow
        exit 1
    }
    try {
        $raw = Get-Content $ConfigPath -Raw -Encoding UTF8
        $cfg = $raw | ConvertFrom-Json
        # Validate required fields
        $required = @('gateway', 'username', 'password', 'targetSSID', 'checkIntervalSeconds')
        foreach ($field in $required) {
            if (-not $cfg.PSObject.Properties.Name.Contains($field) -or
                [string]::IsNullOrWhiteSpace($cfg.$field.ToString())) {
                Write-Host ('ERROR: Missing or empty field in config.json: ' + $field) -ForegroundColor Red
                exit 1
            }
        }
        return $cfg
    }
    catch {
        Write-Host ('ERROR: Failed to parse config.json: ' + $_) -ForegroundColor Red
        exit 1
    }
}

# -----------------------------------------------------------
#  SSID CHECK
# -----------------------------------------------------------

function Get-CurrentSSID {
    try {
        $output = netsh wlan show interfaces 2>$null
        foreach ($line in $output) {
            # Match "    SSID                   : SomeName" but NOT "    BSSID"
            if ($line -match '^\s+SSID\s+:\s+(.+)$' -and $line -notmatch 'BSSID') {
                return $Matches[1].Trim()
            }
        }
    }
    catch {}
    return $null
}

# -----------------------------------------------------------
#  CONNECTIVITY CHECK
# -----------------------------------------------------------

function Test-InternetAccess {
    try {
        $resp = Invoke-WebRequest -Uri $NcsiUrl -UseBasicParsing -TimeoutSec 8 `
            -MaximumRedirection 0 -ErrorAction Stop
        return ($resp.Content -eq $NcsiExpected)
    }
    catch {
        return $false
    }
}

# -----------------------------------------------------------
#  LOGIN FLOW - Confirmed working per spec
# -----------------------------------------------------------

function Invoke-PortalLogin {
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config
    )

    $gateway = $Config.gateway

    # Step 1: GET the gateway root
    # Confirmed by the user: a direct GET to the gateway root triggers
    # FortiGate redirect to /fgtauth?<token> and returns the login page.
    Write-Log ('Fetching login page from ' + $gateway + '/') -Level INFO
    $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
    $resp = $null

    try {
        $resp = Invoke-WebRequest -Uri ($gateway + '/') -UseBasicParsing -TimeoutSec 15 `
            -WebSession $session -Headers $BrowserHeaders -ErrorAction Stop
    }
    catch {
        Write-Log ('Cannot reach gateway: ' + $_) -Level ERROR

        # Fallback: try triggering via an external HTTP URL
        Write-Log 'Trying external-URL fallback trigger...' -Level INFO
        $fallbackUrls = @(
            'http://www.msftconnecttest.com/redirect',
            'http://detectportal.firefox.com/canonical.html',
            'http://www.gstatic.com/generate_204'
        )
        foreach ($url in $fallbackUrls) {
            try {
                Write-Log ('Fallback: GET ' + $url) -Level DEBUG
                $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15 `
                    -WebSession $session -Headers $BrowserHeaders -ErrorAction Stop
                if ($resp.Content -match 'magic' -or $resp.Content -match 'fgtauth') {
                    Write-Log 'Portal intercepted via fallback!' -Level INFO
                    break
                }
                $resp = $null
            }
            catch {
                Write-Log ('Fallback failed: ' + $url) -Level DEBUG
                continue
            }
        }
        if (-not $resp) {
            Write-Log 'All login page fetch attempts failed.' -Level ERROR
            return $false
        }
    }

    $pageHtml = $resp.Content
    $snippetLen = [Math]::Min(200, $pageHtml.Length)
    Write-Log ('Got response: ' + $pageHtml.Length + ' chars') -Level DEBUG

    # Step 2: Extract the magic token
    $magic = $null
    $patterns = @(
        'name="magic"\s+value="([0-9a-fA-F]+)"',
        'value="([0-9a-fA-F]+)"\s+name="magic"',
        "name='magic'\s+value='([0-9a-fA-F]+)'"
    )
    foreach ($pat in $patterns) {
        if ($pageHtml -match $pat) {
            $magic = $Matches[1]
            break
        }
    }

    if (-not $magic) {
        if ($pageHtml -match 'Firewall Authentication' -or $pageHtml -match 'fgtauth') {
            Write-Log 'Login page loaded but magic token not found!' -Level ERROR
        }
        else {
            Write-Log 'Did not land on the login page.' -Level WARN
        }
        Write-Log ('Page snippet: ' + $pageHtml.Substring(0, $snippetLen)) -Level DEBUG
        return $false
    }

    $magicPreview = $magic.Substring(0, [Math]::Min(8, $magic.Length))
    Write-Log ('Got fresh magic token: ' + $magicPreview + '...') -Level INFO

    # Step 3: POST the login form
    $body = @{
        '4Tredir'  = 'http://www.msftconnecttest.com/redirect'
        'magic'    = $magic
        'username' = $Config.username
        'password' = $Config.password
    }
    try {
        $postResp = Invoke-WebRequest -Uri ($gateway + '/') -Method POST -Body $body `
            -UseBasicParsing -TimeoutSec 15 -WebSession $session `
            -Headers $BrowserHeaders -ErrorAction Stop
        Write-Log ('Login POST -> HTTP ' + $postResp.StatusCode) -Level INFO
    }
    catch {
        Write-Log ('Login POST failed: ' + $_) -Level ERROR
        return $false
    }

    # Step 4: Verify it worked
    Start-Sleep -Seconds 3
    if (Test-InternetAccess) {
        Write-Log 'Login successful! Internet is live.' -Level INFO
        return $true
    }
    else {
        Write-Log 'Login POST completed but internet still not reachable.' -Level WARN
        return $false
    }
}

# -----------------------------------------------------------
#  MAIN LOOP
# -----------------------------------------------------------

try {
    $config = Get-Config

    $checkInterval = [int]$config.checkIntervalSeconds
    $targetSSID    = $config.targetSSID

    Write-Log '======================================================='
    Write-Log 'WiFi Keep-Alive Mark 2 started'
    Write-Log ('Gateway:        ' + $config.gateway)
    Write-Log ('Username:       ' + $config.username)
    Write-Log ('Target SSID:    ' + $targetSSID)
    Write-Log ('Check interval: ' + $checkInterval + 's')
    Write-Log ('Verbose log:    ' + $(if ($VerbosePreference -eq 'Continue') { $DebugLogPath } else { 'off' }))
    Write-Log '======================================================='

    Show-Toast -Title 'WiFi Keep-Alive' -Body ('Monitoring started for SSID: ' + $targetSSID)

    $consecutiveFailures = 0
    $startTime = Get-Date

    while ($true) {
        try {
            # Determine check interval (boot grace vs normal)
            $uptime = (Get-Date) - $startTime
            $inBootGrace = ($uptime.TotalSeconds -lt $BootGracePeriodSeconds)
            $currentInterval = if ($inBootGrace) { $BootCheckIntervalSeconds } else { $checkInterval }

            # SSID check: are we on the target network?
            $currentSSID = Get-CurrentSSID
            if (-not $currentSSID) {
                Write-Log 'No WiFi network connected.' -Level DEBUG
                if (-not $inBootGrace) {
                    $consecutiveFailures = 0
                }
                Start-Sleep -Seconds $currentInterval
                continue
            }

            if ($currentSSID -ne $targetSSID) {
                Write-Log ('On "' + $currentSSID + '" (not target) - skipping.') -Level DEBUG
                $consecutiveFailures = 0
                Start-Sleep -Seconds $currentInterval
                continue
            }

            # We are on the target SSID. Check connectivity.
            if (Test-InternetAccess) {
                if ($consecutiveFailures -gt 0) {
                    Write-Log ('Connection restored after ' + $consecutiveFailures + ' failed check(s).')
                }
                $consecutiveFailures = 0
                Write-Log 'Connected - all good.' -Level DEBUG
            }
            else {
                $consecutiveFailures++
                Write-Log ('Disconnected on "' + $targetSSID + '" (check #' + $consecutiveFailures + ') - attempting login...')

                $success = Invoke-PortalLogin -Config $config

                if ($success) {
                    $consecutiveFailures = 0
                    Show-Toast -Title 'WiFi Keep-Alive' -Body ('Reconnected to ' + $targetSSID)
                }
                elseif ($consecutiveFailures -le $MaxFastRetries) {
                    Write-Log ('Retrying in 15s (attempt ' + $consecutiveFailures + '/' + $MaxFastRetries + ')...')
                    Start-Sleep -Seconds 15
                    continue
                }
                else {
                    Write-Log 'Multiple failures. Backing off to normal interval.' -Level WARN
                }
            }

            Start-Sleep -Seconds $currentInterval

            # Handle -RunOnce
            if ($RunOnce) {
                Write-Log 'RunOnce mode - exiting after single check.'
                break
            }
        }
        catch {
            Write-Log ('Unexpected error in main loop: ' + $_) -Level ERROR
            Start-Sleep -Seconds 30
        }
    }
}
finally {
    try {
        $script:mutex.ReleaseMutex()
        $script:mutex.Dispose()
    }
    catch {}
    Write-Log 'WiFi Keep-Alive stopped.'
}
