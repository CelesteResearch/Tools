[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path $PSScriptRoot -Parent),
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Release',
    [string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$pathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$root = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$moduleRoot = [IO.Path]::GetFullPath((Join-Path $root 'Mods/TAS'))
$assembly = Join-Path $moduleRoot "bin/$Configuration/netstandard2.1/Celeste.Mods.Tas.dll"
$manifest = Join-Path $moduleRoot 'everest.yaml'
$luaSource = Join-Path $moduleRoot 'Lua/env.lua'
if (-not (Test-Path -LiteralPath $luaSource -PathType Leaf)) { throw "TAS source runtime script missing: $luaSource" }
# Query resolved runtime references, including packages omitted from a library's normal bin directory.
# Shared's portable publication is authoritative for assemblies supplied by both hosts.
$metadataRoot = Join-Path $root 'artifacts/tas-install-metadata'
$hostClosure = & (Join-Path $PSScriptRoot 'Get-PortableBuiltAssemblyClosure.ps1') -SharedRoot (Join-Path $root 'Shared') -OutputDirectory (Join-Path $metadataRoot 'Shared') -Configuration $Configuration
$project = Join-Path $moduleRoot 'Celeste.Mods.Tas.csproj'
$raw = & dotnet msbuild $project -nologo -verbosity:quiet -target:ResolveReferences -p:BuildProjectReferences=false -p:CopyLocalLockFileAssemblies=true "-p:Configuration=$Configuration" -getProperty:TargetPath -getItem:ReferenceCopyLocalPaths
if ($LASTEXITCODE -ne 0) { throw 'TAS runtime reference resolution failed.' }
$resolved = ($raw -join "`n") | ConvertFrom-Json
$resolved | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $metadataRoot 'Tas.references.json') -Encoding utf8
$sharedAssemblies = @{}
foreach ($entry in $hostClosure.Assemblies) { $sharedAssemblies[$entry.FileName] = $entry }
$privateAssemblies = @{}
$excluded = [Collections.Generic.List[object]]::new()
foreach ($path in @($resolved.Properties.TargetPath) + @($resolved.Items.ReferenceCopyLocalPaths | ForEach-Object FullPath)) {
    if ([IO.Path]::GetExtension($path) -ine '.dll') { continue }
    $path = (Resolve-Path -LiteralPath $path).Path
    $name = [IO.Path]::GetFileName($path)
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sharedAssemblies.ContainsKey($name)) {
        if ($hash -cne $sharedAssemblies[$name].SHA256) { throw "TAS and host resolve different bytes for shared dependency $name; align their builds before installing." }
        $excluded.Add([pscustomobject]@{ FileName = $name; SHA256 = $hash; Reason = 'SharedHostPublication' })
        continue
    }
    $identity = [Reflection.AssemblyName]::GetAssemblyName($path)
    if ($identity.Name -in @('System.Private.CoreLib', 'mscorlib', 'netstandard') -or $path -match '[\\/]packs[\\/].*[\\/]ref[\\/]') {
        throw "SDK core/reference assembly cannot be installed as a private Mod dependency: $path"
    }
    if ($privateAssemblies.ContainsKey($name) -and $privateAssemblies[$name].SHA256 -cne $hash) { throw "Conflicting private TAS dependencies: $name" }
    $privateAssemblies[$name] = [pscustomobject]@{ FileName = $name; Path = $path; SHA256 = $hash; Identity = $identity.FullName }
}
$assemblies = @($privateAssemblies.Values | Sort-Object FileName | ForEach-Object Path)
$assets = Join-Path $root 'Content/Celeste/Mods/TAS'
if (-not $OutputDirectory) { $OutputDirectory = $assets }
$output = [IO.Path]::GetFullPath($OutputDirectory)
$boundary = $root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $output.StartsWith($boundary, $pathComparison)) { throw 'TAS output must be inside the selected workspace.' }
if (-not (Test-Path -LiteralPath $assembly -PathType Leaf)) { throw "Build Mods/TAS/Celeste.Mods.Tas.csproj first; compiled module missing: $assembly" }
foreach ($dependency in $assemblies) { if (-not (Test-Path -LiteralPath $dependency -PathType Leaf)) { throw "Build the TAS module and companions first; missing: $dependency" } }
if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { throw "TAS source manifest missing: $manifest" }
foreach ($directory in @('Dialog', 'Graphics')) {
    if (-not (Test-Path -LiteralPath (Join-Path $assets $directory) -PathType Container)) { throw "Restore TAS assets first with AssetRestore/Restore-Assets.ps1 -IncludeRuntimeContent; missing $directory." }
}
[IO.Directory]::CreateDirectory($output) | Out-Null
if (-not [string]::Equals($assets, $output, [StringComparison]::OrdinalIgnoreCase)) {
    foreach ($directory in @('Dialog', 'Graphics')) { Copy-Item -LiteralPath (Join-Path $assets $directory) -Destination $output -Recurse -Force }
}
foreach ($source in @($assemblies) + @($manifest)) {
    $destination = Join-Path $output ([IO.Path]::GetFileName($source))
    Copy-Item -LiteralPath $source -Destination $destination -Force
    if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash) { throw "TAS installation copy differs: $source" }
}
$luaDirectory = Join-Path $output 'bin'
[IO.Directory]::CreateDirectory($luaDirectory) | Out-Null
$luaTarget = Join-Path $luaDirectory 'env.lua'
Copy-Item -LiteralPath $luaSource -Destination $luaTarget -Force
if ((Get-FileHash -LiteralPath $luaSource -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $luaTarget -Algorithm SHA256).Hash -or
    [Convert]::ToBase64String([IO.File]::ReadAllBytes($luaSource)) -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($luaTarget))) {
    throw 'Installed TAS Lua runtime script differs from its source.'
}
$closure = [ordered]@{ Module = 'CelesteTAS'; Configuration = $Configuration; Assemblies = @($privateAssemblies.Values | Sort-Object FileName); SharedHostDependencies = @($excluded) }
$closure | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'RuntimeDependencyClosure.json') -Encoding utf8
Write-Output "Installed optional CelesteTAS module and retained restored assets: $output"
