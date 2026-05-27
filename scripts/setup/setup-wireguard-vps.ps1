# WireGuard VPS Server Setup for Windows (PowerShell)
# Tunnel: VPS 10.10.0.1 <-> Pi 10.10.0.2
# Run as Administrator

param(
    [string]$PiPublicKey = ""
)

# Show help if -h or --help passed
if ($PiPublicKey -eq "-h" -or $PiPublicKey -eq "--help") {
    @"
===========================================
WireGuard VPS Server Setup (Windows)
===========================================

First run:
  .\setup-wireguard-vps.ps1

This outputs your VPS public key. Share it with the Pi admin.

Second run:
  .\setup-wireguard-vps.ps1 -PiPublicKey <pi-public-key>

Prerequisites:
- Install WireGuard: https://www.wireguard.com/install/
- Or run: winget install WireGuard.WireGuard

"@
    exit 0
}

$ErrorActionPreference = "Stop"

$WG_IFACE = "wg0"
$VPS_TUNNEL_IP = "10.10.0.1/24"
$PI_TUNNEL_IP = "10.10.0.2/32"
$WG_PORT = "51820"

$WG_DIR = "$env:ProgramData\WireGuard"
$CONFIG_FILE = "$WG_DIR\$WG_IFACE.conf"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $colors = @{
        "INFO"  = "Green"
        "WARN"  = "Yellow"
        "ERROR" = "Red"
    }
    Write-Host "[$Level] $Message" -ForegroundColor $colors[$Level]
}

function Test-Admin {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Install-WireGuardWindows {
    Write-Log "Checking for WireGuard installation..." "INFO"

    $wgPath = "$env:ProgramFiles\WireGuard\WireGuard.exe"
    if (Test-Path $wgPath) {
        Write-Log "WireGuard client already installed" "INFO"
        return
    }

    if (Get-Command wg.exe -ErrorAction SilentlyContinue) {
        Write-Log "WireGuard tools already available" "INFO"
        return
    }

    Write-Log "Installing WireGuard..." "INFO"
    Write-Log "Please install WireGuard for Windows from: https://www.wireguard.com/install/" "WARN"
    Write-Log "Or use: winget install WireGuard.WireGuard" "INFO"
    throw "WireGuard not installed. Please install it first."
}

function Get-WireGuardKeys {
    Write-Log "Generating VPS key pair..." "INFO"

    if (-not (Test-Path $WG_DIR)) {
        New-Item -ItemType Directory -Path $WG_DIR -Force | Out-Null
    }

    $privateKeyFile = "$WG_DIR\privatekey"
    $publicKeyFile = "$WG_DIR\publickey"

    if ((Test-Path $privateKeyFile) -and (Test-Path $publicKeyFile)) {
        Write-Log "Keys already exist, skipping generation" "WARN"
    } else {
        if (Get-Command wg.exe -ErrorAction SilentlyContinue) {
            $privateKey = wg genkey
            $privateKey | Out-File -FilePath $privateKeyFile -NoNewline -Encoding utf8
            $publicKey = wg pubkey < $privateKeyFile
            $publicKey | Out-File -FilePath $publicKeyFile -NoNewline -Encoding utf8
        } else {
            Write-Log "wg.exe not available - generating keys externally" "WARN"
            Write-Log "Run in WSL or use: wg genkey | tee privatekey | wg pubkey > publickey" "INFO"
            throw "Cannot generate keys: wg.exe not found"
        }
    }

    $script:VPS_PRIVATE_KEY = Get-Content $privateKeyFile -Raw.Trim()
    $script:VPS_PUBLIC_KEY = Get-Content $publicKeyFile -Raw.Trim()
    Write-Log "VPS public key: $script:VPS_PUBLIC_KEY" "INFO"
}

function Write-WireGuardConfig {
    param([string]$PiPubKey)

    if ([string]::IsNullOrWhiteSpace($PiPubKey)) {
        throw "Pi public key is required"
    }

    Write-Log "Writing WireGuard server config..." "INFO"

    $config = @"
[Interface]
Address = $VPS_TUNNEL_IP
ListenPort = $WG_PORT
PrivateKey = $VPS_PRIVATE_KEY

# Raspberry Pi
[Peer]
PublicKey = $PiPubKey
AllowedIPs = $PI_TUNNEL_IP
PersistentKeepalive = 25
"@

    $config | Out-File -FilePath $CONFIG_FILE -Encoding utf8
    Write-Log "Config written to: $CONFIG_FILE" "INFO"
}

function Open-Firewall {
    Write-Log "Opening WireGuard port $WG_PORT/udp..." "INFO"

    # Check if rule already exists
    $existingRule = Get-NetFirewallRule -DisplayName "WireGuard" -ErrorAction SilentlyContinue

    if ($existingRule) {
        Write-Log "Firewall rule already exists" "WARN"
    } else {
        New-NetFirewallRule -DisplayName "WireGuard" `
            -Direction Inbound `
            -Protocol UDP `
            -LocalPort $WG_PORT `
            -Action Allow `
            -Profile Any | Out-Null
        Write-Log "Firewall rule created" "INFO"
    }
}

function Enable-WireGuardService {
    Write-Log "Enabling WireGuard tunnel..." "INFO"

    $service = Get-Service -Name "WireGuard" -ErrorAction SilentlyContinue

    if ($service) {
        Write-Log "Using Windows WireGuard service" "INFO"
    } else {
        Write-Log "WireGuard service not found - import config manually" "WARN"
    }
}

function Show-Status {
    Write-Host ""
    Write-Log "WireGuard VPS Windows Setup Complete" "INFO"
    Write-Host ""
    Write-Host "Tunnel Configuration:" -ForegroundColor Cyan
    Write-Host "  VPS tunnel IP: 10.10.0.1"
    Write-Host "  Pi tunnel IP:  10.10.0.2"
    Write-Host "  Listen Port:   $WG_PORT/udp"
    Write-Host ""

    if ($PiPublicKey -and (Test-Path $CONFIG_FILE)) {
        Write-Host "Config file: $CONFIG_FILE" -ForegroundColor Green
        Write-Host "Import this file in WireGuard client to start the server." "INFO"

        Write-Host ""
        Write-Host "Update your VPS .env:" -ForegroundColor Cyan
        Write-Host "  RASPI_ENDPOINT=http://10.10.0.2:8080"
    } else {
        Write-Log "Run with Pi public key to complete setup:" "INFO"
        Write-Host "  .\setup-wireguard-vps.ps1 -PiPublicKey <key>" "INFO"
    }
}

# Main
function Main {
    if (-not (Test-Admin)) {
        throw "Please run as Administrator"
    }

    Install-WireGuardWindows
    Get-WireGuardKeys

    if ([string]::IsNullOrWhiteSpace($PiPublicKey)) {
        Write-Host ""
        Write-Log "VPS public key (give this to the Pi setup script):" "INFO"
        Write-Host "  $VPS_PUBLIC_KEY" -ForegroundColor Cyan
        Write-Host ""
        Write-Log "Run again with the Pi's public key to finish setup:" "INFO"
        Write-Host "  .\setup-wireguard-vps.ps1 -PiPublicKey <pi-public-key>" "INFO"
        exit 0
    }

    Write-WireGuardConfig -PiPubKey $PiPublicKey
    Open-Firewall
    Enable-WireGuardService
    Show-Status
}

Main
