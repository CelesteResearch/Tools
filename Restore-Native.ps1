[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CelesteDirectory,
    [string]$RepositoryRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$OdinDirectory,
    [string]$NativeDependencyDirectory,
    [string]$RuntimeIdentifier
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Platform.ps1')
. (Join-Path $PSScriptRoot 'NativeLibraryAliases.ps1')
$RuntimeIdentifier = Get-CelesteRuntimeIdentifier $RuntimeIdentifier
if ($RuntimeIdentifier -notin @('win-x64', 'linux-x64', 'osx-x64')) { throw 'The FMOD 1.10.14 desktop closure requires x64. On Apple Silicon use x64 hosts and PowerShell through Rosetta.' }
$root = [IO.Path]::GetFullPath($RepositoryRoot)
$game = Get-CelesteInstallationDirectory $CelesteDirectory
$native = Join-Path $root "artifacts/runtime/$RuntimeIdentifier"
$sharedNative = Join-Path $root "Shared/artifacts/runtime/$RuntimeIdentifier"
$hasUnity = Test-Path -LiteralPath (Join-Path $root 'Unity/ProjectSettings/ProjectVersion.txt') -PathType Leaf

function Copy-VerifiedNative([string]$Source, [string]$TargetDirectory) {
    [IO.Directory]::CreateDirectory($TargetDirectory) | Out-Null
    $destination = Join-Path $TargetDirectory ([IO.Path]::GetFileName($Source))
    $hash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
    if (-not (Test-Path -LiteralPath $destination -PathType Leaf) -or (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $hash) {
        Copy-Item -LiteralPath $Source -Destination $destination -Force
    }
    if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $hash) { throw "Native dependency copy differs: $Source" }
    return $hash
}

function Copy-NativeAlias([string]$Source, [string]$Destination) {
    $hash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
    if ((Test-Path -LiteralPath $Destination -PathType Leaf) -and (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -ceq $hash) { return }
    if (Get-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue) { Remove-Item -LiteralPath $Destination -Force }
    Copy-Item -LiteralPath $Source -Destination $Destination
}

function Get-LinuxFmodDeployment([string]$Source) {
    $bytes = [IO.File]::ReadAllBytes($Source)
    $length = [uint64]$bytes.LongLength
    if ($length -lt 64 -or $bytes[0] -ne 0x7f -or $bytes[1] -ne 0x45 -or $bytes[2] -ne 0x4c -or $bytes[3] -ne 0x46 -or $bytes[4] -ne 2 -or $bytes[5] -ne 1 -or $bytes[6] -ne 1) {
        throw "FMOD requires a valid little-endian ELF64 library: $Source"
    }
    if ([BitConverter]::ToUInt16($bytes, 16) -ne 3 -or [BitConverter]::ToUInt16($bytes, 18) -ne 62 -or [BitConverter]::ToUInt32($bytes, 20) -ne 1 -or [BitConverter]::ToUInt16($bytes, 52) -ne 64) {
        throw "FMOD requires an x64 ELF shared library with a valid header: $Source"
    }
    $programOffset = [BitConverter]::ToUInt64($bytes, 32)
    $entrySize = [BitConverter]::ToUInt16($bytes, 54)
    $entryCount = [BitConverter]::ToUInt16($bytes, 56)
    if ($entrySize -ne 56 -or $entryCount -eq 0 -or $entryCount -eq 65535 -or $programOffset -lt 64 -or $programOffset -gt $length -or [uint64]$entryCount -gt [Math]::Floor(($length - $programOffset) / 56)) {
        throw "FMOD ELF program headers are missing or outside the file: $Source"
    }
    $stackFlagsOffset = $null
    for ($index = 0; $index -lt $entryCount; $index++) {
        $offset = [int]($programOffset + [uint64]$index * 56)
        $segmentOffset = [BitConverter]::ToUInt64($bytes, $offset + 8)
        $segmentSize = [BitConverter]::ToUInt64($bytes, $offset + 32)
        if ($segmentOffset -gt $length -or $segmentSize -gt $length - $segmentOffset) { throw "FMOD ELF segment extends outside the file: $Source" }
        if ([BitConverter]::ToUInt32($bytes, $offset) -ne 1685382481) { continue }
        if ($null -ne $stackFlagsOffset) { throw "FMOD ELF has duplicate GNU stack headers: $Source" }
        $stackFlagsOffset = $offset + 4
    }
    if ($null -eq $stackFlagsOffset) { throw "FMOD ELF has no GNU stack program header: $Source" }
    $sourceHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    $originalFlags = [BitConverter]::ToUInt32($bytes, $stackFlagsOffset)
    $deploymentFlags = [uint32]($originalFlags -band 4294967294)
    if ($originalFlags -ne $deploymentFlags) {
        [Array]::Copy([BitConverter]::GetBytes($deploymentFlags), 0, $bytes, $stackFlagsOffset, 4)
    }
    return [pscustomobject]@{
        Bytes = $bytes
        SourceSHA256 = $sourceHash
        SHA256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
        Normalization = [pscustomobject]@{ Kind = 'ElfGnuStack'; FlagsOffset = $stackFlagsOffset; SourceFlags = $originalFlags; DeployedFlags = $deploymentFlags; Changed = $originalFlags -ne $deploymentFlags }
    }
}

$libraryNames = if ($RuntimeIdentifier -eq 'win-x64') {
    @('SDL2.dll', 'FAudio.dll', 'FNA3D.dll', 'libtheorafile.dll', 'fmod64.dll', 'fmodstudio.dll', 'lua54.dll')
}
elseif ($RuntimeIdentifier -eq 'linux-x64') {
    @('libSDL2-2.0.so.0', 'libFAudio.so.0', 'libFNA3D.so.0', 'libtheorafile.so', 'libfmod.so', 'libfmodstudio.so', 'libfmod_SDL.so', 'liblua54.so')
}
else {
    @('libSDL2-2.0.0.dylib', 'libFAudio.0.dylib', 'libFNA3D.0.dylib', 'libtheorafile.dylib', 'libfmod.dylib', 'libfmodstudio.dylib', 'liblua54.dylib', 'libMoltenVK.dylib')
}
$searchRoots = @(
    if ($NativeDependencyDirectory) { (Resolve-Path -LiteralPath $NativeDependencyDirectory).Path }
    Join-Path $game "runtimes/$RuntimeIdentifier/native"
    Join-Path $game $(switch ($RuntimeIdentifier) { 'win-x64' { 'lib64-win-x64' } 'linux-x64' { 'lib64' } 'osx-x64' { 'osx' } })
    Join-Path $game 'lib64'
    Join-Path $game 'orig/lib64'
    Join-Path $game 'orig/osx'
    Join-Path $game 'orig'
    Join-Path $game $(switch ($RuntimeIdentifier) { 'win-x64' { 'everest-lib/lib64-win-x64' } 'linux-x64' { 'everest-lib/lib64-linux' } 'osx-x64' { 'everest-lib/lib64-osx' } })
    Join-Path $game 'Contents/MacOS'
    Join-Path $game 'Contents/Resources'
    Join-Path $root "Shared/lib/Native/$RuntimeIdentifier"
    $game
) | Select-Object -Unique
# Resolve and validate the complete closure before copying any dependency.
$pending = foreach ($name in $libraryNames) {
    $aliases = @($name)
    switch ($name) {
        'libSDL2-2.0.so.0' { $aliases += @('libSDL2.so', 'libSDL2-2.0.so') }
        'libFAudio.so.0' { $aliases += 'libFAudio.so' }
        'libFNA3D.so.0' { $aliases += 'libFNA3D.so' }
        'libfmod.so' { $aliases += @('libfmod.so.10', 'libfmod.so.10.14') }
        'libfmodstudio.so' { $aliases += @('libfmodstudio.so.10', 'libfmodstudio.so.10.14') }
        'libSDL2-2.0.0.dylib' { $aliases += 'libSDL2.dylib' }
        'libFAudio.0.dylib' { $aliases += 'libFAudio.dylib' }
        'libFNA3D.0.dylib' { $aliases += 'libFNA3D.dylib' }
        'liblua54.so' { $aliases += @('liblua5.4.so', 'liblua5.4.so.0') }
        'liblua54.dylib' { $aliases += @('liblua5.4.dylib', 'liblua.5.4.dylib') }
    }
    $source = foreach ($directory in $searchRoots) {
        foreach ($alias in $aliases) {
            $candidate = Join-Path $directory $alias
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $candidate }
        }
    }
    $source = $source | Select-Object -First 1
    if (-not $source) { throw "Native dependency missing for $RuntimeIdentifier`: $name. Supply -NativeDependencyDirectory with the matching platform's libraries." }
    $architectures = @(Get-CelesteNativeArchitectures $source)
    if ($RuntimeIdentifier -notin $architectures) { throw "Native dependency architecture mismatch: $source contains $($architectures -join ', '), expected $RuntimeIdentifier." }
    $isFmod = $name -match '^((lib)?fmod)'
    if ($isFmod -and $RuntimeIdentifier -eq 'win-x64') {
        $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($source).FileVersion
        if ($version -notlike '1.10.14*') { throw "FMOD ABI requires 1.10.14; found $version in $name" }
    }
    $deployment = if ($RuntimeIdentifier -eq 'linux-x64' -and $name -in @('libfmod.so', 'libfmodstudio.so')) { Get-LinuxFmodDeployment $source } else { $null }
    $sourceHash = if ($deployment) { $deployment.SourceSHA256 } else { (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash }
    [pscustomobject]@{ Name = $name; Source = $source; Fmod = $isFmod; Deployment = $deployment; SourceSHA256 = $sourceHash; SHA256 = $(if ($deployment) { $deployment.SHA256 } else { $sourceHash }) }
}
$results = foreach ($item in $pending) {
    [IO.Directory]::CreateDirectory($native) | Out-Null
    # Canonical names also retain the SONAME filenames needed by transitive native imports.
    $destination = Join-Path $native $item.Name
    $hash = $item.SHA256
    $existing = Get-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
    if ($existing.LinkTarget) { Remove-Item -LiteralPath $destination -Force }
    if (-not (Test-Path -LiteralPath $destination -PathType Leaf) -or (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -cne $hash) {
        if ($item.Deployment) { [IO.File]::WriteAllBytes($destination, $item.Deployment.Bytes) }
        else { Copy-Item -LiteralPath $item.Source -Destination $destination -Force }
    }
    if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -cne $hash) { throw "Native copy differs: $destination" }
    $canonical = if ($item.Name.StartsWith('libSDL2')) { Get-CelesteNativeFileName 'SDL2' $RuntimeIdentifier }
    elseif ($item.Name.StartsWith('libFAudio')) { Get-CelesteNativeFileName 'FAudio' $RuntimeIdentifier }
    elseif ($item.Name.StartsWith('libFNA3D')) { Get-CelesteNativeFileName 'FNA3D' $RuntimeIdentifier }
    else { $item.Name }
    if ($canonical -cne $item.Name) { Copy-NativeAlias $destination (Join-Path $native $canonical) }
    $soname = if ($RuntimeIdentifier -eq 'linux-x64' -and $item.Name -in @('libfmod.so', 'libfmodstudio.so')) { $item.Name + '.10' } else { $null }
    if ($soname) { Copy-NativeAlias $destination (Join-Path $native $soname) }
    if ($hasUnity) {
        $pluginPath = Get-CelesteUnityPluginDirectory (Join-Path $root 'Unity') $RuntimeIdentifier -Fmod:$item.Fmod
        $pluginPrimary = Join-Path $pluginPath $item.Name
        $existingPlugin = Get-Item -LiteralPath $pluginPrimary -Force -ErrorAction SilentlyContinue
        if ($existingPlugin.LinkTarget) { Remove-Item -LiteralPath $pluginPrimary -Force }
        Copy-VerifiedNative $destination $pluginPath | Out-Null
        if ($canonical -cne $item.Name) { Copy-NativeAlias $pluginPrimary (Join-Path $pluginPath $canonical) }
        if ($soname) { Copy-NativeAlias $pluginPrimary (Join-Path $pluginPath $soname) }
    }
    [pscustomobject]@{ File = $item.Name; SourceSHA256 = $item.SourceSHA256; SHA256 = $hash; Normalization = $(if ($item.Deployment) { $item.Deployment.Normalization } else { $null }); RuntimeIdentifier = $RuntimeIdentifier; Aliases = @($canonical, $soname | Where-Object { $_ -and $_ -cne $item.Name }) }
}
Set-CelesteNativeLibraryAliases -Directory $native -RuntimeIdentifier $RuntimeIdentifier
if ($hasUnity) {
    foreach ($fmod in @($false, $true)) {
        $pluginPath = Get-CelesteUnityPluginDirectory (Join-Path $root 'Unity') $RuntimeIdentifier -Fmod:$fmod
        Set-CelesteNativeLibraryAliases -Directory $pluginPath -RuntimeIdentifier $RuntimeIdentifier
    }
}
if (Test-Path -LiteralPath $sharedNative -PathType Container) {
    foreach ($file in Get-ChildItem -LiteralPath $sharedNative -File) {
        if ($file.Extension -notin @('.dll', '.so', '.dylib')) { continue }
        Copy-VerifiedNative $file.FullName $native | Out-Null
    }
}
$results | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $native 'manifest.json') -Encoding utf8
if ($hasUnity -and $OdinDirectory) {
    $source = (Resolve-Path -LiteralPath $OdinDirectory).Path
    if (-not (Test-Path -LiteralPath (Join-Path $source 'Assemblies/Sirenix.OdinInspector.Editor.dll') -PathType Leaf)) { throw 'OdinDirectory must be the licensed Sirenix directory containing Assemblies/Sirenix.OdinInspector.Editor.dll.' }
    $target = Join-Path $root 'Unity/Assets/Plugins/Sirenix'
    if (-not [string]::Equals([IO.Path]::GetFullPath($source).TrimEnd([IO.Path]::DirectorySeparatorChar), [IO.Path]::GetFullPath($target).TrimEnd([IO.Path]::DirectorySeparatorChar), $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }))) {
        [IO.Directory]::CreateDirectory($target) | Out-Null
        Copy-Item -Path (Join-Path $source '*') -Destination $target -Recurse -Force
    }
}
Write-Output "Restored $($libraryNames.Count) $RuntimeIdentifier native dependencies to $native; Unity plugins: $hasUnity."
