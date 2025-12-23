# pre-bootstrap.ps1
# Stage-0 bootstrap: input staging only
# Safe to re-run. No hardening. No security changes.

[CmdletBinding()]
param (
    [switch]$NfsPersist,
    [switch]$RunWinBootstrap
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
