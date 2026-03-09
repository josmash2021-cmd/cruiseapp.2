# ── Cruise Backend Startup Script (Auto-Restart Watchdog) ──
# Starts uvicorn + cloudflared tunnel with automatic recovery.
# The server stays online as long as the PC is running.
# Usage:  .\start_server.ps1
# ───────────────────────────────────────────────────────────

$ErrorActionPreference = "Continue"
$backendDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $backendDir

$HEALTH_CHECK_INTERVAL = 15   # seconds between health checks
$HEALTH_TIMEOUT         = 5   # seconds to wait for /health response
$MAX_CONSECUTIVE_FAILS  = 3   # restart after this many failed checks
$TUNNEL_CHECK_INTERVAL  = 60  # seconds between tunnel connectivity checks

# ── Helper: Start Uvicorn ──────────────────────────────
function Start-Server {
    Write-Host "[SERVER] Starting uvicorn..." -ForegroundColor Cyan
    $job = Start-Job -ScriptBlock {
        Set-Location $using:backendDir
        python -m uvicorn main:app --host 0.0.0.0 --port 8000 --timeout-keep-alive 120
    }
    # Wait for server to be ready
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 1
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:8000/health" -UseBasicParsing -TimeoutSec $HEALTH_TIMEOUT -ErrorAction Stop
            if ($r.StatusCode -eq 200) {
                Write-Host "[SERVER] UP on port 8000" -ForegroundColor Green
                return $job
            }
        } catch {}
    }
    Write-Host "[SERVER] WARNING: Did not respond within 20s, continuing..." -ForegroundColor Yellow
    return $job
}

# ── Helper: Start Cloudflare Tunnel ────────────────────
function Start-Tunnel {
    Write-Host "[TUNNEL] Starting cloudflared..." -ForegroundColor Cyan
    $tunnelLog = Join-Path $backendDir "tunnel.log"
    if (Test-Path $tunnelLog) { Remove-Item $tunnelLog -Force }
    $proc = Start-Process -FilePath "cloudflared" `
        -ArgumentList "tunnel", "--url", "http://localhost:8000" `
        -RedirectStandardError $tunnelLog `
        -PassThru -NoNewWindow:$false -WindowStyle Hidden

    # Parse tunnel URL
    $url = $null
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        if (Test-Path $tunnelLog) {
            $content = Get-Content $tunnelLog -Raw -ErrorAction SilentlyContinue
            if ($content -match 'https://[a-z0-9-]+\.trycloudflare\.com') {
                $url = $Matches[0]
                break
            }
        }
    }

    if ($url) {
        $url | Out-File -FilePath (Join-Path $backendDir "tunnel_url.txt") -Encoding utf8 -NoNewline
        Write-Host "[TUNNEL] URL: $url" -ForegroundColor Green
    } else {
        Write-Host "[TUNNEL] WARNING: Could not detect URL" -ForegroundColor Yellow
    }
    return @{ Process = $proc; Url = $url }
}

# ── Helper: Check tunnel is reachable ──────────────────
function Test-TunnelHealth {
    param([string]$url)
    if (-not $url) { return $false }
    try {
        $r = Invoke-WebRequest -Uri "$url/health" -UseBasicParsing -TimeoutSec $HEALTH_TIMEOUT -ErrorAction Stop
        return ($r.StatusCode -eq 200)
    } catch {
        return $false
    }
}

# ── INITIAL STARTUP ───────────────────────────────────
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Cruise Backend — Auto-Restart Watchdog" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""

# Kill any leftover processes
Get-Process -Name python -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process -Name cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

$serverJob = Start-Server
$tunnel = Start-Tunnel

Write-Host ""
Write-Host "=== Backend is running ===" -ForegroundColor Green
Write-Host "  Local:  http://localhost:8000" -ForegroundColor White
if ($tunnel.Url) {
    Write-Host "  Tunnel: $($tunnel.Url)" -ForegroundColor White
}
Write-Host ""
Write-Host "  Watchdog active — auto-restarts on crash" -ForegroundColor DarkGray
Write-Host "  Press Ctrl+C to stop everything." -ForegroundColor DarkGray
Write-Host ""

# ── WATCHDOG LOOP ─────────────────────────────────────
$consecutiveFails = 0
$lastTunnelCheck = [DateTime]::MinValue

try {
    while ($true) {
        Start-Sleep -Seconds $HEALTH_CHECK_INTERVAL

        # Print any server output
        Receive-Job $serverJob -ErrorAction SilentlyContinue

        # ── Check if uvicorn job is still running ──
        if ($serverJob.State -ne 'Running') {
            Write-Host "[WATCHDOG] Server job stopped (state=$($serverJob.State)). Restarting..." -ForegroundColor Red
            Receive-Job $serverJob -ErrorAction SilentlyContinue
            Remove-Job $serverJob -Force -ErrorAction SilentlyContinue
            # Kill any leftover python processes on port 8000
            Get-Process -Name python -ErrorAction SilentlyContinue | Stop-Process -Force
            Start-Sleep -Seconds 2
            $serverJob = Start-Server
            $consecutiveFails = 0
            continue
        }

        # ── Health check ──
        $healthy = $false
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:8000/health" -UseBasicParsing -TimeoutSec $HEALTH_TIMEOUT -ErrorAction Stop
            if ($r.StatusCode -eq 200) { $healthy = $true }
        } catch {}

        if ($healthy) {
            if ($consecutiveFails -gt 0) {
                Write-Host "[WATCHDOG] Server recovered." -ForegroundColor Green
            }
            $consecutiveFails = 0
        } else {
            $consecutiveFails++
            Write-Host "[WATCHDOG] Health check failed ($consecutiveFails/$MAX_CONSECUTIVE_FAILS)" -ForegroundColor Yellow
            if ($consecutiveFails -ge $MAX_CONSECUTIVE_FAILS) {
                Write-Host "[WATCHDOG] Server unresponsive. Force-restarting..." -ForegroundColor Red
                Stop-Job $serverJob -ErrorAction SilentlyContinue
                Remove-Job $serverJob -Force -ErrorAction SilentlyContinue
                Get-Process -Name python -ErrorAction SilentlyContinue | Stop-Process -Force
                Start-Sleep -Seconds 3
                $serverJob = Start-Server
                $consecutiveFails = 0
            }
        }

        # ── Tunnel check (less frequent) ──
        $now = [DateTime]::Now
        if (($now - $lastTunnelCheck).TotalSeconds -ge $TUNNEL_CHECK_INTERVAL) {
            $lastTunnelCheck = $now

            # Check if cloudflared process is alive
            $tunnelAlive = $false
            if ($tunnel.Process -and -not $tunnel.Process.HasExited) {
                $tunnelAlive = $true
            }

            if (-not $tunnelAlive) {
                Write-Host "[WATCHDOG] Tunnel process died. Restarting..." -ForegroundColor Red
                Get-Process -Name cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force
                Start-Sleep -Seconds 2
                $tunnel = Start-Tunnel
            } elseif ($tunnel.Url) {
                # Verify tunnel is reachable
                if (-not (Test-TunnelHealth $tunnel.Url)) {
                    Write-Host "[WATCHDOG] Tunnel unreachable. Restarting..." -ForegroundColor Yellow
                    if ($tunnel.Process -and -not $tunnel.Process.HasExited) {
                        Stop-Process -Id $tunnel.Process.Id -Force -ErrorAction SilentlyContinue
                    }
                    Start-Sleep -Seconds 3
                    $tunnel = Start-Tunnel
                }
            }
        }
    }
} finally {
    Write-Host "`nShutting down..." -ForegroundColor Yellow
    Stop-Job $serverJob -ErrorAction SilentlyContinue
    Remove-Job $serverJob -Force -ErrorAction SilentlyContinue
    Get-Process -Name python -ErrorAction SilentlyContinue | Stop-Process -Force
    if ($tunnel.Process -and -not $tunnel.Process.HasExited) {
        Stop-Process -Id $tunnel.Process.Id -Force -ErrorAction SilentlyContinue
    }
    Get-Process -Name cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force
    Write-Host "Done." -ForegroundColor Green
}
