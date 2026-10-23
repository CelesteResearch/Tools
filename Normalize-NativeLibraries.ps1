[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Directory,
    [Parameter(Mandatory)][string]$RuntimeIdentifier
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'NativeLibraryAliases.ps1')
Set-CelesteNativeLibraryAliases -Directory $Directory -RuntimeIdentifier $RuntimeIdentifier
