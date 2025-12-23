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

.PARAMETER Force
    When specified, allows re-running stage-0 bootstrap even if it has already
    completed. Existing metadata is preserved and replaced explicitly.

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

.EXAMPLE
    .\pre-bootstrap.ps1 `
        -NfsServer nfs.example.net `
        -NfsShare /srv/bootstrap `
        -Force

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
    [switch]$RunWinBootstrap,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -------------------------
# Constants
# -------------------------

$BootstrapRoot = 'C:\bootstrap'
$MetaRoot      = Join-Path $BootstrapRoot 'meta'
$NfsDrive      = 'Z:'

$RemoteWinBootstrap = 'win-bootstrap.ps1'
$AnsibleKey         = 'ssh\id_ansible.pub'

$Stage0Json      = Join-Path $MetaRoot 'stage0.json'
$Stage0Completed = Join-Path $MetaRoot 'stage0.completed'
$Stage0Previous  = Join-Path $MetaRoot 'stage0.previous.json'

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
# Re-run protection
# -------------------------

if (Test-Path $Stage0Completed) {
    if (-not $Force) {
        throw @"
Stage-0 bootstrap has already completed.

Refusing to run again to prevent accidental reinitialization.

If you REALLY intend to re-run stage-0, re-invoke with:
  -Force
"@
    }

    if (Test-Path $Stage0Json) {
        Move-Item -Path $Stage0Json -Destination $Stage0Previous -Force
    }
}

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
        mount.exe -o anon $remote $NfsDrive | Out-Null
    }
}

function Ensure-NfsUnmounted {
    $driveName = $NfsDrive.TrimEnd(':')

    if (Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue) {
        umount.exe $NfsDrive
    }
}

# -------------------------
# Local staging layout
# -------------------------

function Ensure-BootstrapLayout {
    $paths = @(
        $BootstrapRoot,
        (Join-Path $BootstrapRoot 'ssh'),
        $MetaRoot
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
    -Source (Join-Path $NfsDrive $AnsibleKey) `
    -Destination (Join-Path $BootstrapRoot $AnsibleKey)

# -------------------------
# Write metadata (stage-0 contract)
# -------------------------

$metadata = @{
    schema_version = 1
    stage          = 'pre-bootstrap'

    invocation = @{
        timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
        hostname      = $env:COMPUTERNAME
        user          = $env:USERNAME
        pid           = $PID
    }

    source = @{
        nfs_server    = $NfsServer
        nfs_share     = $NfsShare
        mounted_drive = $NfsDrive
    }

    artifacts = @{
        win_bootstrap = (Join-Path $BootstrapRoot 'win-bootstrap.ps1')
        ssh_keys      = @(
            (Join-Path $BootstrapRoot $AnsibleKey)
        )
    }

    intent = @{
        run_win_bootstrap = [bool]$RunWinBootstrap
        nfs_persist       = [bool]$NfsPersist
        force             = [bool]$Force
    }
}

$metadata |
    ConvertTo-Json -Depth 4 |
    Set-Content -Path $Stage0Json -Encoding UTF8

New-Item -ItemType File -Path $Stage0Completed -Force | Out-Null

# -------------------------
# Optional execution
# -------------------------

if ($RunWinBootstrap) {
    & (Join-Path $BootstrapRoot 'win-bootstrap.ps1')
}

# -------------------------
# Teardown
# -------------------------

if (-not $NfsPersist) {
    Ensure-NfsUnmounted
}
