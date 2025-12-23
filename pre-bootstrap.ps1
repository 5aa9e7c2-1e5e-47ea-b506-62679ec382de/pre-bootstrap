<#
.SYNOPSIS
    Stage-0 bootstrap script for Windows Server 2022 systems.

.DESCRIPTION
    pre-bootstrap.ps1 prepares a freshly installed Windows Server host for
    secure configuration management by staging all required inputs locally
    under C:\bootstrap.

    This script is intentionally limited in scope. It:
      - Installs the Windows NFS client feature if required
      - Temporarily mounts a read-only NFS share
      - Copies bootstrap artifacts (scripts and public keys) to local storage
      - Optionally invokes win-bootstrap.ps1

    This script explicitly DOES NOT:
      - Perform any security hardening
      - Modify authentication or authorization settings
      - Establish or remove remote access mechanisms
      - Require internet access
      - Make persistent configuration changes outside C:\bootstrap

    All security-sensitive actions are deferred to win-bootstrap.ps1, which
    consumes only locally staged inputs and never accesses network shares.

.DESIGN PRINCIPLES
    - Safe and idempotent to re-run
    - Each step independently verifiable
    - Each step reversible
    - No environment-wide or irreversible changes
    - Prefer explicit operator intent over implicit defaults

.PARAMETER NfsServer
    DNS name or IP address of the NFS server hosting bootstrap materials.

.PARAMETER NfsShare
    NFS export path containing bootstrap materials (for example: /srv/share).

.PARAMETER NfsPersist
    When specified, the NFS share is left mounted after the script completes.
    When omitted, the NFS share is unmounted before exit.

.PARAMETER RunWinBootstrap
    When specified, invokes win-bootstrap.ps1 after staging completes.
    Execution is explicit and never implicit.

.ASSUMPTIONS
    - Windows Server 2022
    - Script is executed with Administrator privileges
    - NFS export is read-only and anonymously accessible
    - No interactive input is available

.EXAMPLE
    .\pre-bootstrap.ps1 `
        -NfsServer nfs.example.net `
        -NfsShare /srv/bootstrap

.EXAMPLE
    .\pre-bootstrap.ps1 `
        -NfsServer nfs.example.net `
        -NfsShare /srv/bootstrap `
        -RunWinBootstrap

.NOTES
    This script is designed for controlled, side-by-side migrations where
    safety, observability, and reversibility are prioritized over speed.

    After win-bootstrap.ps1 completes successfully, all further configuration
    changes must be performed via a configuration management system over SSH.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$NfsServer,

    [Parameter(Mandatory = $true)]
    [string]$NfsShare,

    [switch]$NfsPersist,
    [switch]$RunWinBootstrap
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -------------------------
# Constants
# -------------------------

$BootstrapRoot = 'C:\bootstrap'
$NfsDrive      = 'Z:'

$RemoteWinBootstrap = 'win-bootstrap.ps1'
$RemoteAnsibleKey   = 'ssh\ansible.pub'

# -------------------------
# Preconditions
# -------------------------

function Assert-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdmin) {
        throw "pre-bootstrap.ps1 must be run as Administrator"
    }
}

Assert-Admin

# -------------------------
# NFS client feature
# -------------------------

function Ensure-NfsClient {
    $feature = Get-WindowsFeature -Name NFS-Client
    if (-not $feature.Installed) {
        Install-WindowsFeature -Name NFS-Client -IncludeManagementTools
    }
}

# -------------------------
# NFS mount lifecycle
# -------------------------

function Ensure-NfsMounted {
    $driveName = $NfsDrive.TrimEnd(':')

    if (-not (Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue)) {
        $remote = "\\$NfsServer$NfsShare"
        mount -o anon $remote $NfsDrive | Out-Null
    }
}

function Ensure-NfsUnmounted {
    $driveName = $NfsDrive.TrimEnd(':')

    if (Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue) {
        umount $NfsDrive
    }
}

# -------------------------
# Local staging layout
# -------------------------

function Ensure-BootstrapLayout {
    $paths = @(
        $BootstrapRoot,
        Join-Path $BootstrapRoot 'ssh',
        Join-Path $BootstrapRoot 'meta'
    )

    foreach ($path in $paths) {
        if (-not (Test-Path $path)) {
            New-Item -ItemType Directory -Path $path | Out-Null
        }
    }
}

# -------------------------
# Staging helpers
# -------------------------

function Stage-File {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    if (-not (Test-Path $Destination)) {
        Copy-Item -Path $Source -Destination $Destination -Force
    }
}

# -------------------------
# Execution flow
# -------------------------

Ensure-NfsClient
Ensure-NfsMounted
Ensure-BootstrapLayout

# Stage win-bootstrap.ps1
Stage-File `
    -Source (Join-Path $NfsDrive $RemoteWinBootstrap) `
    -Destination (Join-Path $BootstrapRoot 'win-bootstrap.ps1')

# Stage SSH public key(s)
Stage-File `
    -Source (Join-Path $NfsDrive $RemoteAnsibleKey) `
    -Destination (Join-Path $BootstrapRoot 'ssh\ansible.pub')

# Optional execution
if ($RunWinBootstrap) {
    & (Join-Path $BootstrapRoot 'win-bootstrap.ps1')
}

# Teardown unless persistence explicitly requested
if (-not $NfsPersist) {
    Ensure-NfsUnmounted
}
