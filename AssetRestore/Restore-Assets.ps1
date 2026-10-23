[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CelesteDirectory,
    [Parameter(Mandatory)][string]$RepositoryRoot,
    [switch]$IncludeRuntimeContent,
    [switch]$IncludeMods,
    [string]$TasArchive,
    [string]$AudioBankDirectory,
    [string]$FrameworkDirectory,
    [string]$FrameworkTimeResourceDirectory
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Platform.ps1')
$gameRoot = Get-CelesteInstallationDirectory $CelesteDirectory
$targetRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$manifestFile = Join-Path $PSScriptRoot 'resource-map.json'
$project = Join-Path $PSScriptRoot 'ResourceExtractor/ResourceExtractor.csproj'
$toolOutput = Join-Path $targetRoot 'artifacts/tools/ResourceExtractor'
$tool = Join-Path $toolOutput 'ResourceExtractor.dll'
$manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json

function Resolve-Destination([string]$Relative) {
    if ([IO.Path]::IsPathRooted($Relative)) { throw "Expected a relative destination: $Relative" }
    $absolute = [IO.Path]::GetFullPath((Join-Path $targetRoot $Relative))
    $boundary = $targetRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $absolute.StartsWith($boundary, $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }))) {
        throw "Destination is outside the selected repository: $Relative"
    }
    return $absolute
}

function Copy-Verified([string]$Source, [string]$Relative) {
    $destination = Resolve-Destination $Relative
    $sourceHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
    if ((Test-Path -LiteralPath $destination) -and (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -eq $sourceHash) { return }
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $destination -Force
    if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $sourceHash) {
        throw "Copied content differs: $Relative"
    }
}

function Write-ZipEntry([IO.Compression.ZipArchiveEntry]$Entry, [string]$Relative) {
    if ([IO.Path]::IsPathRooted($Entry.FullName) -or $Entry.FullName.Replace('\', '/').Split('/') -contains '..') {
        throw "ZIP entry has an unsafe path: $($Entry.FullName)"
    }
    $destination = Resolve-Destination $Relative
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
    $source = $Entry.Open()
    try {
        $output = [IO.File]::Create($destination)
        try { $source.CopyTo($output) } finally { $output.Dispose() }
    }
    finally { $source.Dispose() }
    $source = $Entry.Open()
    try { $expected = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($source)) }
    finally { $source.Dispose() }
    if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $expected) {
        throw "Extracted content differs: $($Entry.FullName)"
    }
}

function Write-ModuleMetadata([string]$Relative, [string]$Name, [string]$Version) {
    $destination = Resolve-Destination $Relative
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
    [IO.File]::WriteAllText($destination, "- Name: $Name`n  Version: $Version`n")
}

& dotnet build $project -c Release --output $toolOutput --nologo --verbosity quiet
if ($LASTEXITCODE -ne 0) { throw 'Embedded resource extraction tool failed to build.' }
& dotnet $tool $gameRoot $targetRoot $manifestFile
if ($LASTEXITCODE -ne 0) { throw 'Embedded resource extraction failed.' }
if (-not $IncludeRuntimeContent) { return }

$gameContent = Join-Path $gameRoot 'Content'
if (-not (Test-Path -LiteralPath (Join-Path $gameContent 'Maps/1-ForsakenCity.bin'))) {
    throw 'The selected installation does not contain the original game Content directory.'
}
$contentCount = 0
foreach ($directory in @('Maps', 'Graphics', 'Dialog', 'Tutorials', 'Overworld', 'Monocle', 'Effects')) {
    $sourceDirectory = Join-Path $gameContent $directory
    if (-not (Test-Path -LiteralPath $sourceDirectory)) { continue }
    foreach ($file in Get-ChildItem -LiteralPath $sourceDirectory -File -Recurse) {
        if ($file.Extension.ToLowerInvariant() -in @('.bank', '.fsb', '.ogg', '.mp3', '.wav', '.aiff', '.flac')) {
            throw "Audio must be provided through -AudioBankDirectory: $($file.Name)"
        }
        $relative = [IO.Path]::GetRelativePath($gameContent, $file.FullName)
        if ($file.Extension -eq '.meta') { $relative = [IO.Path]::ChangeExtension($relative, '.atlas.bytes') }
        Copy-Verified $file.FullName ('Content/Celeste/' + $relative)
        $contentCount++
    }
}

$unityTemplate = Resolve-Destination 'Unity/Assets/WebGLTemplates/Celeste'
if (Test-Path -LiteralPath (Join-Path $unityTemplate 'index.html') -PathType Leaf) {
    # Embedded extraction above restores the stock effects required by the shared graphics codecs.
    $artworkProject = Join-Path $PSScriptRoot 'WebTouchArtwork/WebTouchArtwork.csproj'
    $artworkOutput = Resolve-Destination 'artifacts/tools/WebTouchArtwork'
    & dotnet build $artworkProject -c Release --output $artworkOutput --nologo --verbosity quiet
    if ($LASTEXITCODE -ne 0) { throw 'Web touch artwork tool failed to build.' }
    & dotnet (Join-Path $artworkOutput 'WebTouchArtwork.dll') $gameContent (Join-Path $unityTemplate 'touch')
    if ($LASTEXITCODE -ne 0) { throw 'Original GUI touch artwork could not be restored.' }
}

# The built-in Core source provides the same installed resources without executing its assembly.
foreach ($file in $manifest.files) {
    if ($file.set -ne 'installed' -or -not $file.resource.StartsWith('Content/') -or $file.resource.StartsWith('Content/Lua/')) { continue }
    Copy-Verified (Resolve-Destination $file.destination) ('Content/Everest/Core/' + $file.resource.Substring(8))
}
Write-ModuleMetadata 'Content/Everest/Core/everest.yaml' 'Everest' '1.6580.0'

if (-not $TasArchive -and (Test-Path -LiteralPath (Join-Path $gameRoot 'Mods') -PathType Container)) {
    $candidate = Get-ChildItem -LiteralPath (Join-Path $gameRoot 'Mods') -Filter 'CelesteTAS*.zip' -File |
        Sort-Object Name | Select-Object -First 1
    if ($candidate) { $TasArchive = $candidate.FullName }
}
if ($TasArchive) {
    $archive = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $TasArchive).Path)
    try {
        foreach ($entry in $archive.Entries) {
            if (-not $entry.Name) { continue }
            if ($entry.FullName.StartsWith('Dialog/') -or $entry.FullName.StartsWith('Graphics/')) {
                Write-ZipEntry $entry ('Content/Celeste/Mods/TAS/' + $entry.FullName)
            }
            if ($entry.FullName -in @('Dialog/Fonts/JetBrainsMono-Regular.fnt', 'Dialog/Fonts/JetBrainsMono-Regular_0.png')) {
                Write-ZipEntry $entry ('Content/Celeste/' + $entry.FullName)
            }
        }
    }
    finally { $archive.Dispose() }
    # Install-Tas.ps1 supplies a real module manifest together with the compiled port DLL.
    $tasManifest = Resolve-Destination 'Content/Celeste/Mods/TAS/everest.yaml'
    if (Test-Path -LiteralPath $tasManifest) {
        $existing = [IO.File]::ReadAllText($tasManifest)
        if ($existing -notmatch '(?m)^\s*DLL:') { Remove-Item -LiteralPath $tasManifest }
    }

}
else { Write-Output 'No optional CelesteTAS asset ZIP found; base game restoration continues without it.' }

if ($IncludeMods) {
    Write-Output 'Mod packaging is deferred until managed assemblies are built. Run Tools/Pack-Mods.ps1 with the installation Mods directory; no original Mod DLL was copied.'
}

if ($AudioBankDirectory) {
    $banks = (Resolve-Path -LiteralPath $AudioBankDirectory).Path
    foreach ($required in @('Master Bank.bank', 'Master Bank.strings.bank')) {
        if (-not (Test-Path -LiteralPath (Join-Path $banks $required))) { throw "FMOD bank missing: $required" }
    }
    foreach ($bank in Get-ChildItem -LiteralPath $banks -Filter '*.bank' -File) {
        Copy-Verified $bank.FullName ('Content/Celeste/FMOD/Desktop/' + $bank.Name)
    }
}
else {
    Write-Warning 'FMOD banks were not restored. Supply -AudioBankDirectory with Desktop banks built from the official FMOD project before running.'
}

$timeRoot = Resolve-Destination 'Content/CelesteFrameworkTimeResources'
if ($FrameworkTimeResourceDirectory) {
    if (-not (Test-Path -LiteralPath (Join-Path $FrameworkTimeResourceDirectory 'mscorlib.resources'))) {
        throw 'FrameworkTimeResourceDirectory must contain mscorlib.resources.'
    }
    foreach ($file in Get-ChildItem -LiteralPath (Resolve-Path -LiteralPath $FrameworkTimeResourceDirectory).Path -Filter 'mscorlib*.resources' -File) {
        Copy-Verified $file.FullName ('Content/CelesteFrameworkTimeResources/' + $file.Name)
    }
}
else {
    if (-not $FrameworkDirectory -and $IsWindows) { $FrameworkDirectory = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319' }
    if (-not $FrameworkDirectory) { throw 'Supply -FrameworkTimeResourceDirectory or a .NET Framework directory containing mscorlib.dll.' }
    $framework = (Resolve-Path -LiteralPath $FrameworkDirectory).Path
    & dotnet $tool --extract (Join-Path $framework 'mscorlib.dll') 'mscorlib.resources' (Join-Path $timeRoot 'mscorlib.resources')
    if ($LASTEXITCODE -ne 0) { throw '.NET Framework time resources could not be restored.' }
    $satellite = Join-Path $framework 'zh-Hans/mscorlib.resources.dll'
    if (Test-Path -LiteralPath $satellite) {
        & dotnet $tool --extract $satellite 'mscorlib.zh-HANS.resources' (Join-Path $timeRoot 'mscorlib.zh-HANS.resources')
        if ($LASTEXITCODE -ne 0) { throw 'Chinese .NET Framework resources could not be restored.' }
    }
}
Write-Output ("Restored {0} original content files plus built-in Everest/TAS assets. No game process or installation settings were changed." -f $contentCount)
