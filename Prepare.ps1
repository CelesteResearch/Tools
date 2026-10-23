[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CelesteDirectory,
    [string]$AudioBankDirectory,
    [string]$UnityEditorDirectory,
    [string]$OdinDirectory,
    [ValidateSet('All', 'Unity', 'Godot', 'Managed')][string]$Targets = 'All',
    [string]$CMakeExecutable,
    [switch]$IncludeHelpers,
    [switch]$WithoutTas,
    [switch]$CompileOnly,
    [string]$RuntimeIdentifier,
    [string]$NativeDependencyDirectory,
    [string]$FrameworkDirectory,
    [string]$FrameworkTimeResourceDirectory
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Platform.ps1')
$RuntimeIdentifier = Get-CelesteRuntimeIdentifier $RuntimeIdentifier
$root = Split-Path $PSScriptRoot -Parent
$unity = Join-Path $root 'Unity'
$shared = Join-Path $root 'Shared'
$godot = Join-Path $root 'Godot'
$rebuildPlan = $null
try {
    if ($IncludeHelpers) {
        . (Join-Path $PSScriptRoot 'LockedModRecipes.ps1')
        . (Join-Path $PSScriptRoot 'Restore-ModDecompiler.ps1')
        . (Join-Path $PSScriptRoot 'WorkspaceModRecipes.ps1')
        $installation = Get-CelesteInstallationDirectory $CelesteDirectory
        # All registered recipe repositories are required here; internal partial qualification is not a Prepare fallback.
        $rebuildPlan = Get-WorkspaceModRecipePlan -RepositoryRoot $root -CelesteDirectory $installation -ToolsDirectory $PSScriptRoot
    }
    $restore = @{ CelesteDirectory = $CelesteDirectory; RepositoryRoot = $root }
    if ($FrameworkDirectory) { $restore.FrameworkDirectory = $FrameworkDirectory }
    if ($FrameworkTimeResourceDirectory) { $restore.FrameworkTimeResourceDirectory = $FrameworkTimeResourceDirectory }
    if (-not $CompileOnly) { $restore.IncludeRuntimeContent = $true; if ($AudioBankDirectory) { $restore.AudioBankDirectory = $AudioBankDirectory } }
    & (Join-Path $PSScriptRoot 'AssetRestore/Restore-Assets.ps1') @restore
    Push-Location $root
    try {
        & dotnet build (Join-Path $shared 'Shared.slnx') -c Release "-p:CelesteRuntimeIdentifier=$RuntimeIdentifier" --nologo -v minimal -m:4
        if ($LASTEXITCODE -ne 0) { throw 'Shared managed build failed.' }
        if ($IncludeHelpers) {
            & dotnet build (Join-Path $PSScriptRoot 'Helpers.slnx') -c Release "-p:CelesteRuntimeIdentifier=$RuntimeIdentifier" --nologo -v minimal -m:4
            if ($LASTEXITCODE -ne 0) { throw 'Helper managed build failed.' }
            $rebuiltPackages = @()
            if ($rebuildPlan) {
                $packages = @(Invoke-LockedModRecipeBuildAndPack -Plan $rebuildPlan -PackModScript (Join-Path $PSScriptRoot 'Pack-Mod.ps1'))
                if ($packages.Count -ne $rebuildPlan.Modules.Count) { throw 'Not every locked module produced a rebuilt package.' }
                $rebuiltPackages = @(
                    foreach ($module in $rebuildPlan.Modules) {
                        $matchesForModule = @($packages | Where-Object Id -CEQ $module.Id)
                        if ($matchesForModule.Count -ne 1) { throw "Expected one rebuilt package for $($module.Id)." }
                        $package = $matchesForModule[0]
                        $original = @($rebuildPlan.Inputs | Where-Object Path -CEQ $module.Archive | Select-Object -First 1)[0]
                        [pscustomobject]@{
                            Id = $package.Id
                            Version = $package.Version
                            Archive = $package.Archive
                            ArchiveSha256 = $package.ArchiveSha256
                            AssemblySha256 = $package.AssemblySha256
                            AssemblyFileName = [IO.Path]::GetFileName($module.Assembly)
                            SourceArchive = $module.Archive
                            SourceArchiveSha256 = $original.Sha256
                        }
                    }
                )
            }
            if (-not $CompileOnly) {
                & (Join-Path $PSScriptRoot 'Pack-Mods.ps1') -SourceModsDirectory (Join-Path $installation 'Mods') -RepositoryRoot $root -RebuiltPackages $rebuiltPackages -RequireAll
            }
        }
        if (-not $WithoutTas) {
            $tasProject = Join-Path $root 'Mods/TAS/Celeste.Mods.Tas.csproj'
            if (Test-Path -LiteralPath $tasProject -PathType Leaf) {
                & dotnet build $tasProject -c Release "-p:CelesteRuntimeIdentifier=$RuntimeIdentifier" --nologo -v minimal -m:4
                if ($LASTEXITCODE -ne 0) { throw 'TAS module build failed.' }
                if (-not $CompileOnly) { & (Join-Path $PSScriptRoot 'Install-Tas.ps1') -RepositoryRoot $root }
            }
            else { Write-Warning 'Optional TAS repository is not cloned; TAS module preparation was skipped.' }
        }
        if ($Targets -eq 'Managed') { return }
        $native = @{ RepositoryRoot = $root; UnityEditorDirectory = $UnityEditorDirectory; WithoutUnity = ($Targets -eq 'Godot'); RuntimeIdentifier = $RuntimeIdentifier }
        if ($CMakeExecutable) { $native.CMakeExecutable = $CMakeExecutable }
        & (Join-Path $PSScriptRoot 'Build-Native.ps1') @native
        & (Join-Path $PSScriptRoot 'Restore-Native.ps1') -CelesteDirectory $CelesteDirectory -RepositoryRoot $root -OdinDirectory $OdinDirectory -RuntimeIdentifier $RuntimeIdentifier -NativeDependencyDirectory $NativeDependencyDirectory
        if ($Targets -in @('All', 'Unity')) {
            & dotnet build (Join-Path $unity 'Tools/DependencyIsolation/Celeste.Tools.DependencyIsolation.csproj') -c Release "-p:CelesteRuntimeIdentifier=$RuntimeIdentifier" --nologo -v minimal
            if ($LASTEXITCODE -ne 0) { throw 'Dependency isolation tool build failed.' }
            & (Join-Path $unity 'Tools/Sync-SharedAssemblies.ps1') -UnityRoot $unity -SharedRoot $shared -RuntimeIdentifier $RuntimeIdentifier
            if (-not (Test-Path -LiteralPath (Join-Path $unity 'Assets/Plugins/Sirenix/Assemblies/Sirenix.OdinInspector.Editor.dll'))) { Write-Warning 'Install your licensed Odin Inspector into Unity/Assets/Plugins/Sirenix before opening Unity, or pass -OdinDirectory.' }
        }
        if ($Targets -in @('All', 'Godot')) {
            & (Join-Path $godot 'Tools/Sync-SharedAssemblies.ps1') -GodotRoot $godot -SharedRoot $shared -RuntimeIdentifier $RuntimeIdentifier
            & dotnet build (Join-Path $godot 'CelesteGodot.csproj') -c Debug "-p:CelesteRuntimeIdentifier=$RuntimeIdentifier" --nologo -v minimal
            if ($LASTEXITCODE -ne 0) { throw 'Godot host build failed.' }
        }
    }
    finally { Pop-Location }
}
finally {
    if ($rebuildPlan -and $rebuildPlan.ScratchRoot) {
        Remove-RecipeScratch -Path $rebuildPlan.ScratchRoot -RepositoryRoot $root
    }
}
