# WiFi Keep-Alive

**Auto-login for college WiFi captive portals (FortiGate).** Pure PowerShell, zero dependencies, one-command install.

Your college WiFi kicks you out every 3 hours? This keeps you logged in forever.

## Install (one command)

Open **PowerShell as Administrator**, paste this, and hit Enter:

```powershell
irm https://raw.githubusercontent.com/Vnainva/wifi-keepalive/main/web-install.ps1 | iex
```

That's it. It downloads everything, asks for your WiFi credentials, and starts running.

### Manual Install (alternative)

Download the [latest release ZIP](https://github.com/Vnainva/wifi-keepalive/releases/latest), extract, and run:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

The installer will:
1. Create `%LOCALAPPDATA%\WifiKeepAlive\` (clean path, no spaces)
2. Walk you through entering your gateway, credentials, and WiFi SSID
3. Register a Scheduled Task that starts at every login
4. Show a toast notification confirming installation

**That's it.** It runs silently in the background from now on.

## How It Works

```
Every 2.5 minutes:
  ├─ Are we on the target WiFi SSID?
  │   └─ No  → do nothing (saves battery, avoids false positives)
  │   └─ Yes ↓
  ├─ GET http://www.msftconnecttest.com/connecttest.txt
  │   └─ Response = "Microsoft Connect Test"? → online, do nothing
  │   └─ Otherwise → captive portal intercepted us!
  │
  ├─ GET http://gateway:port/
  │   └─ FortiGate redirects to /fgtauth?<fresh-one-time-token>
  │   └─ Scrape the 'magic' hidden field from the HTML
  │
  └─ POST http://gateway:port/
      └─ username + password + magic + 4Tredir
      └─ Verify internet works → ✅ toast notification "Reconnected!"
```

## Features

- **Pure PowerShell** — no Python, no pip, no Node. Ships with Windows.
- **Single-instance guard** — named mutex prevents duplicate processes.
- **SSID-aware** — only runs when connected to your college WiFi.
- **Toast notifications** — on start and reconnect only. No spam.
- **No log file by default** — run with `-Verbose` for debug logging.
- **Boot-tolerant** — checks every 20s for the first 3 minutes after start, so it doesn't fail if WiFi isn't up yet.
- **Config file** — credentials in `%LOCALAPPDATA%\WifiKeepAlive\config.json`, not in the script.

## Files

| File | Purpose |
|---|---|
| `wifi-keepalive.ps1` | Main script (the keep-alive loop) |
| `install.ps1` | One-command installer with config wizard |
| `uninstall.ps1` | Clean removal of everything |
| `config.example.json` | Config template (safe to commit) |

## Configuration

Config lives at `%LOCALAPPDATA%\WifiKeepAlive\config.json`:

```json
{
  "gateway": "http://YOUR_GATEWAY_IP:PORT",
  "username": "your_username",
  "password": "your_password",
  "targetSSID": "YourCollegeSSID",
  "checkIntervalSeconds": 150
}
```

## Debugging

Run the script manually with verbose output:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA%\WifiKeepAlive\wifi-keepalive.ps1" -Verbose
```

Single check + login attempt (doesn't loop):

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA%\WifiKeepAlive\wifi-keepalive.ps1" -RunOnce -Verbose
```

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\WifiKeepAlive\uninstall.ps1"
```

Removes the Scheduled Task, kills running instances, and deletes the install folder (prompts before deleting your config).

## Requirements

- Windows 10 or later
- PowerShell 5.1+ (built into Windows)
- Administrator privileges (for Scheduled Task registration)

## License

MIT
