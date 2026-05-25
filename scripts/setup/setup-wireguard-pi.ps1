# WireGuard Pi Client Setup for Windows (PowerShell)
# Tunnel: Pi 10.10.0.2 <-> VPS 10.10.0.1
# Run as Administrator

param(
    [string]$VpsPublicKey = ""
)

# Show help if -h or --help passed
if ($VpsPublicKey -eq "-h" -or $VpsPublicKey -eq "--help") {
    @"
===========================================
WireGuard Pi Client Setup (Windows)
===========================================

First run:
  .\setup-wireguard-pi.ps1

This outputs your Pi public key. Share it with the VPS admin.

Second run:
  .\setup-wireguard-pi.ps1 -VpsPublicKey <vps-public-key>

Prerequisites:
- Install WireGuard: https://www.wireguard.com/install/
- Or run: winget install WireGuard.WireGuard

"@
    exit 0
}

$ErrorActionPreference = "Stop"

$WG_IFACE = "wg0"
$PI_TUNNEL_IP = "10.10.0.2/24"
$VPS_TUNNEL_IP = "10.10.0.1/32"
$VPS_PORT = "51820"
$VPS_PUBLIC_IP = if ($env:VPS_PUBLIC_IP) { $env:VPS_PUBLIC_IP } else { "178.104.6.176" }

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

    # Check if WireGuard is installed (official client)
    $wgPath = "$env:ProgramFiles\WireGuard\WireGuard.exe"
    if (Test-Path $wgPath) {
        Write-Log "WireGuard client already installed" "INFO"
        return
    }

    # Check if wg.exe exists (wireguard-tools)
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
    Write-Log "Generating Pi key pair..." "INFO"

    if (-not (Test-Path $WG_DIR)) {
        New-Item -ItemType Directory -Path $WG_DIR -Force | Out-Null
    }

    $privateKeyFile = "$WG_DIR\privatekey"
    $publicKeyFile = "$WG_DIR\publickey"

    if ((Test-Path $privateKeyFile) -and (Test-Path $publicKeyFile)) {
        Write-Log "Keys already exist, skipping generation" "WARN"
    } else {
        # Generate keys using wg.exe if available, otherwise generate externally
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

    $script:PI_PRIVATE_KEY = Get-Content $privateKeyFile -Raw.Trim()
    $script:PI_PUBLIC_KEY = Get-Content $publicKeyFile -Raw.Trim()
    Write-Log "Pi public key: $script:PI_PUBLIC_KEY" "INFO"
}

function Write-WireGuardConfig {
    param([string]$VpsPubKey)

    if ([string]::IsNullOrWhiteSpace($VpsPubKey)) {
        throw "VPS public key is required"
    }

    Write-Log "Writing WireGuard client config..." "INFO"

    $config = @"
[Interface]
Address = $PI_TUNNEL_IP
PrivateKey = $PI_PRIVATE_KEY

# VPS server
[Peer]
PublicKey = $VpsPubKey
Endpoint = ${VPS_PUBLIC_IP}:${VPS_PORT}
AllowedIPs = $VPS_TUNNEL_IP
PersistentKeepalive = 25
"@

    $config | Out-File -FilePath $CONFIG_FILE -Encoding utf8
    Write-Log "Config written to: $CONFIG_FILE" "INFO"
}

function Enable-WireGuardService {
    Write-Log "Enabling WireGuard tunnel..." "INFO"

    # Use WireGuard Windows service
    $service = Get-Service -Name "WireGuard" -ErrorAction SilentlyContinue

    if ($service) {
        Write-Log "Using Windows WireGuard service" "INFO"
        # Import config via netsh (or use WireGuard GUI)
        Write-Log "Please import the config in WireGuard GUI or run:" "INFO"
        Write-Log "  `$wg = Get-WireGuardConfiguration -Path '$CONFIG_FILE'" "INFO"
    } else {
        # Fallback: Use wg-quick via WSL or manual
        Write-Log "WireGuard service not found" "WARN"
        Write-Log "Import config manually in WireGuard client or use WSL" "WARN"
    }
}

function Test-Tunnel {
    Write-Log "Testing tunnel to VPS..." "INFO"

    Start-Sleep -Seconds 3

    # In Windows, test via WireGuard interface
    if (Get-Command wg.exe -ErrorAction SilentlyContinue) {
        wg show $WG_IFACE 2>$null
        Write-Log "Tunnel interface status checked" "INFO"
    } else {
        Write-Log "Cannot test tunnel without wg.exe - use WireGuard GUI" "WARN"
    }
}

function Show-Status {
    Write-Host ""
    Write-Log "WireGuard Pi Windows Setup Complete" "INFO"
    Write-Host ""
    Write-Host "Tunnel Configuration:" -ForegroundColor Cyan
    Write-Host "  Pi tunnel IP:  10.10.0.2"
    Write-Host "  VPS tunnel IP: 10.10.0.1"
    Write-Host "  VPS public IP: $VPS_PUBLIC_IP"
    Write-Host ""

    if ($VpsPublicKey -and (Test-Path $CONFIG_FILE)) {
        Write-Host "Config file: $CONFIG_FILE" -ForegroundColor Green
        Write-Host "Import this file in WireGuard client to connect." "INFO"
    } else {
        Write-Log "Run with VPS public key to complete setup:" "INFO"
        Write-Host "  .\setup-wireguard-pi.ps1 -VpsPublicKey <key>" "INFO"
    }
}

# Main
function Main {
    if (-not (Test-Admin)) {
        throw "Please run as Administrator"
    }

    Install-WireGuardWindows
    Get-WireGuardKeys

    if ([string]::IsNullOrWhiteSpace($VpsPublicKey)) {
        Write-Host ""
        Write-Log "Pi public key (give this to the VPS setup script):" "INFO"
        Write-Host "  $PI_PUBLIC_KEY" -ForegroundColor Cyan
        Write-Host ""
        Write-Log "Run again with the VPS's public key to finish setup:" "INFO"
        Write-Host "  .\setup-wireguard-pi.ps1 -VpsPublicKey <vps-public-key>" "INFO"
        exit 0
    }

    Write-WireGuardConfig -VpsPubKey $VpsPublicKey
    Enable-WireGuardService
    Test-Tunnel
    Show-Status
}

Main
