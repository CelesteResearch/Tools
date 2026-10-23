[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceModsDirectory,
    [string]$RepositoryRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$OutputDirectory,
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Release',
    [string[]]$Modules = @(),
    [string]$ArchiveOverrides,
    [switch]$SkipContentOnly,
    [switch]$RequireAll,
    [switch]$PlanOnly,
    [string]$ReportPath,
    [object[]]$RebuiltPackages = @()
)

$ErrorActionPreference = 'Stop'
$pathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$root = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$sourceRoot = (Resolve-Path -LiteralPath $SourceModsDirectory).Path
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'Content/Celeste/Mods' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
$rootBoundary = $root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $output.StartsWith($rootBoundary, $pathComparison)) {
    throw 'Mod output must be inside the selected source repository.'
}
if (-not $ReportPath) { $ReportPath = Join-Path $root 'artifacts/mod-packaging.json' }
$reportFile = [IO.Path]::GetFullPath($ReportPath)
if (-not $reportFile.StartsWith($rootBoundary, $pathComparison)) {
    throw 'The packaging report must be inside the selected source repository.'
}
$publicationStarted = $false
try {
    $packer = Join-Path $PSScriptRoot 'Pack-Mod.ps1'
    $configurationFile = Join-Path $PSScriptRoot 'mod-packages.json'
    $packageDefinitions = (Get-Content -LiteralPath $configurationFile -Raw | ConvertFrom-Json).modules
    $yamlLibrary = Join-Path $root 'Shared/lib/Everest/YamlDotNet.dll'
    if (-not (Test-Path -LiteralPath $yamlLibrary)) { throw 'Restore third-party managed dependencies before packaging Mods.' }
    [Reflection.Assembly]::LoadFrom($yamlLibrary) | Out-Null

    function Get-Scalar([object]$Mapping, [string]$Name) {
        foreach ($item in $Mapping.Children.GetEnumerator()) {
            if ($item.Key.Value -eq $Name) {
                if ($item.Value -isnot [YamlDotNet.RepresentationModel.YamlScalarNode]) {
                    throw "The module field '$Name' must be a scalar."
                }
                return $item.Value.Value
            }
        }
        return $null
    }

    function Read-Archive([string]$Path) {
        $archive = [IO.Compression.ZipFile]::OpenRead($Path)
        try {
            $entry = $archive.Entries | Where-Object { $_.FullName -in @('everest.yaml', 'everest.yml') } | Select-Object -First 1
            if (-not $entry) { return [pscustomobject]@{ Path = $Path; Modules = @(); HasCode = $true; Reason = 'No root everest.yaml/everest.yml' } }
            if ($entry.Length -gt 1MB) { throw "Module manifest is larger than 1 MiB: $Path" }
            $reader = [IO.StreamReader]::new($entry.Open())
            try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
            $yaml = [YamlDotNet.RepresentationModel.YamlStream]::new()
            $reader = [IO.StringReader]::new($text)
            try { $yaml.Load($reader) } finally { $reader.Dispose() }
            if ($yaml.Documents.Count -ne 1) { throw "Expected one manifest document: $Path" }
            $node = $yaml.Documents[0].RootNode
            $records = [Collections.Generic.List[object]]::new()
            if ($node -is [YamlDotNet.RepresentationModel.YamlSequenceNode]) {
                foreach ($child in $node.Children) { $records.Add($child) }
            }
            else { $records.Add($node) }
            $metadata = @(
                foreach ($record in $records) {
                    if ($record -isnot [YamlDotNet.RepresentationModel.YamlMappingNode]) { throw "Invalid module manifest: $Path" }
                    $name = Get-Scalar $record 'Name'
                    if (-not $name) { throw "Unnamed module in archive: $Path" }
                    [pscustomobject]@{ Name = $name; Version = Get-Scalar $record 'Version'; DLL = Get-Scalar $record 'DLL' }
                }
            )
            $hasCode = @($metadata | Where-Object DLL).Count -gt 0 -or @($archive.Entries | Where-Object { $_.FullName.EndsWith('.dll', [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
            return [pscustomobject]@{ Path = $Path; Modules = $metadata; HasCode = $hasCode; Reason = $null }
        }
        finally { $archive.Dispose() }
    }

    function Get-AssemblyPaths([string]$Project, [Collections.Generic.HashSet[string]]$Seen) {
        $projectPath = [IO.Path]::GetFullPath($Project)
        if (-not $Seen.Add($projectPath)) { return }
        if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) { throw "Mod project dependency is not cloned: $projectPath" }
        $document = [xml](Get-Content -LiteralPath $projectPath -Raw)
        $name = @($document.Project.PropertyGroup.AssemblyName | Where-Object { $_ })[0]
        if (-not $name) { $name = [IO.Path]::GetFileNameWithoutExtension($projectPath) }
        $projectDirectory = [IO.Path]::GetDirectoryName($projectPath)
        $target = Join-Path $projectDirectory "bin/$Configuration/netstandard2.1/$name.dll"
        [pscustomobject]@{ Project = $projectPath; Assembly = $target }
        foreach ($reference in $document.Project.ItemGroup.ProjectReference) {
            if (-not $reference -or $reference.Include.Contains('$(') -or $reference.Private -eq 'false') { continue }
            $referencedProject = [IO.Path]::GetFullPath((Join-Path $projectDirectory $reference.Include))
            $modsBoundary = [IO.Path]::GetFullPath((Join-Path $root 'Mods')).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
            if ($referencedProject.StartsWith($modsBoundary, $pathComparison)) {
                Get-AssemblyPaths $referencedProject $Seen
            }
        }
    }

    function Verify-PackedAssemblies([string]$Archive, [object[]]$Assemblies) {
        $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
        try {
            foreach ($assembly in $Assemblies) {
                $entry = $zip.GetEntry([IO.Path]::GetFileName($assembly.Assembly))
                if (-not $entry) { throw "Compiled assembly missing from package: $($assembly.Assembly)" }
                $stream = $entry.Open()
                try { $actual = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)) }
                finally { $stream.Dispose() }
                if ($actual -ne (Get-FileHash -LiteralPath $assembly.Assembly -Algorithm SHA256).Hash) {
                    throw "Compiled assembly hash differs in package: $($assembly.Assembly)"
                }
            }
        }
        finally { $zip.Dispose() }
    }

    $archives = @(Get-ChildItem -LiteralPath $sourceRoot -Filter '*.zip' -File | ForEach-Object { Read-Archive $_.FullName })
    $overrides = @{}
    if ($ArchiveOverrides) {
        $document = Get-Content -LiteralPath $ArchiveOverrides -Raw | ConvertFrom-Json
        foreach ($property in $document.PSObject.Properties) { $overrides[$property.Name] = $property.Value }
    }
    $selected = @($packageDefinitions | Where-Object { $Modules.Count -eq 0 -or $_.name -in $Modules })
    foreach ($name in $Modules) { if ($name -notin $packageDefinitions.name -and $name -notin @($RebuiltPackages | ForEach-Object Id)) { throw "No ported module named '$name' is configured." } }
    $plans = [Collections.Generic.List[object]]::new()
    $unavailable = [Collections.Generic.List[object]]::new()
    $missing = [Collections.Generic.List[string]]::new()
    $usedArchives = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($definition in $selected) {
        try {
            $project = Join-Path $root $definition.project
            if (-not (Test-Path -LiteralPath $project -PathType Leaf)) { throw "Module source is not cloned: $project" }
            $assemblies = @(Get-AssemblyPaths $project ([Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)))
            foreach ($assembly in $assemblies) { if (-not (Test-Path -LiteralPath $assembly.Assembly -PathType Leaf)) { throw "Build the module and its dependencies first; assembly missing: $($assembly.Assembly)" } }
        }
        catch {
            if ($Modules.Count -gt 0 -or $RequireAll) { throw }
            $unavailable.Add([pscustomobject]@{ Name = $definition.name; Reason = $_.Exception.Message })
            continue
        }
        $archiveMatches = @($archives | Where-Object {
                @($_.Modules | Where-Object { $_.Name -eq $definition.name -and $_.DLL }).Count -eq 1
            })
        if ($overrides.ContainsKey($definition.name)) {
            $chosen = $overrides[$definition.name]
            if (-not [IO.Path]::IsPathRooted($chosen)) { $chosen = Join-Path $sourceRoot $chosen }
            $chosen = (Resolve-Path -LiteralPath $chosen).Path
            $archiveMatches = @(Read-Archive $chosen)
            if (@($archiveMatches[0].Modules | Where-Object { $_.Name -eq $definition.name -and $_.DLL }).Count -ne 1) { throw "Archive override does not contain code module '$($definition.name)'." }
        }
        if ($archiveMatches.Count -eq 0) { $missing.Add($definition.name); continue }
        if ($archiveMatches.Count -gt 1) { throw "More than one archive provides '$($definition.name)'. Select the source through -ArchiveOverrides." }
        $archive = $archiveMatches[0]
        if (@($archive.Modules | Where-Object DLL).Count -ne 1) { throw "Module '$($definition.name)' needs exactly one DLL manifest declaration for the existing packer." }
        if (-not $usedArchives.Add($archive.Path)) { throw "An archive is selected for more than one ported module: $($archive.Path)" }
        $plans.Add([pscustomobject]@{ Name = $definition.name; Source = $archive.Path; Output = Join-Path $output ([IO.Path]::GetFileName($archive.Path)); Assemblies = $assemblies; Manifest = $definition.manifest })
    }
    if ($RequireAll -and $missing.Count -gt 0) { throw "Missing original content archives: $($missing -join ', ')" }

    $rebuiltPlans = [Collections.Generic.List[object]]::new()
    $outputPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($plan in $plans) { [void]$outputPaths.Add($plan.Output) }
    $rebuiltNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $artifactBoundary = [IO.Path]::GetFullPath((Join-Path $root 'artifacts')).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    foreach ($package in $RebuiltPackages) {
        if ($package.Id -cnotmatch '^[A-Za-z][A-Za-z0-9._-]*$' -or -not $rebuiltNames.Add($package.Id)) { throw 'Invalid or duplicate rebuilt module package.' }
        if ($Modules.Count -gt 0 -and $package.Id -notin $Modules) { throw "A rebuilt package was not selected: $($package.Id)." }
        $source = [IO.Path]::GetFullPath($package.SourceArchive)
        $prepared = [IO.Path]::GetFullPath($package.Archive)
        if (-not $prepared.StartsWith($artifactBoundary, $pathComparison)) { throw 'Rebuilt packages must come from workspace artifacts.' }
        if ($package.ArchiveSha256 -cnotmatch '^[0-9a-f]{64}$' -or $package.SourceArchiveSha256 -cnotmatch '^[0-9a-f]{64}$' -or $package.AssemblySha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Rebuilt package hashes are invalid.' }
        if ((Get-FileHash -LiteralPath $prepared -Algorithm SHA256).Hash.ToLowerInvariant() -cne $package.ArchiveSha256 -or (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -cne $package.SourceArchiveSha256) { throw 'A rebuilt package or original ZIP changed after reconstruction.' }
        $original = @($archives | Where-Object { [string]::Equals($_.Path, $source, $pathComparison) })
        if ($original.Count -ne 1 -or $package.Id -notin $original[0].Modules.Name -or -not $usedArchives.Add($original[0].Path)) { throw 'A rebuilt package does not match one unused original module archive.' }
        $metadata = Read-Archive $prepared
        $codeModules = @($metadata.Modules | Where-Object DLL)
        if ($codeModules.Count -ne 1 -or $codeModules[0].Name -cne $package.Id -or $codeModules[0].Version -cne $package.Version -or $codeModules[0].DLL -cne $package.AssemblyFileName) { throw 'The rebuilt manifest does not match its locked module assembly.' }
        $zip = [IO.Compression.ZipFile]::OpenRead($prepared)
        try {
            $dlls = @($zip.Entries | Where-Object { $_.FullName.EndsWith('.dll', [StringComparison]::OrdinalIgnoreCase) })
            if ($dlls.Count -ne 1 -or $dlls[0].FullName -cne $package.AssemblyFileName) { throw 'Unexpected original or additional DLL in a rebuilt package.' }
            $stream = $dlls[0].Open()
            try { $sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant() }
            finally { $stream.Dispose() }
            if ($sha -cne $package.AssemblySha256) { throw 'The rebuilt package assembly bytes differ from its build output.' }
        }
        finally { $zip.Dispose() }
        $destination = Join-Path $output ($package.Id + '.zip')
        if (-not $outputPaths.Add($destination)) { throw 'Source and rebuilt module packages target the same output.' }
        $rebuiltPlans.Add([pscustomobject]@{ Name = $package.Id; Version = $package.Version; Source = $source; SourceArchiveSha256 = $package.SourceArchiveSha256; Prepared = $prepared; Output = $destination; ArchiveSha256 = $package.ArchiveSha256; AssemblySha256 = $package.AssemblySha256; AssemblyFileName = $package.AssemblyFileName })
    }
    foreach ($destination in @($plans | ForEach-Object Output) + @($rebuiltPlans | ForEach-Object Output)) {
        if (@($archives | Where-Object { [string]::Equals($_.Path, $destination, $pathComparison) }).Count -gt 0) { throw 'Runtime packaging cannot overwrite any original input ZIP.' }
    }
    $contentArchives = @($archives | Where-Object { -not $_.HasCode -and -not $usedArchives.Contains($_.Path) })
    $unsupported = @($archives | Where-Object { $_.HasCode -and -not $usedArchives.Contains($_.Path) } | ForEach-Object { [pscustomobject]@{ Archive = [IO.Path]::GetFileName($_.Path); Modules = @($_.Modules.Name); Reason = if ($_.Reason) { $_.Reason } else { 'No matching ported module selected' } } })
    $temporaryDirectory = Join-Path $root 'artifacts/mod-packaging'
    if (-not $PlanOnly) {
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($reportFile)) | Out-Null
        @{ status = 'running'; modules = @($plans.Name) + @($rebuiltPlans | ForEach-Object Name) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $reportFile -Encoding utf8
        $publicationStarted = $true
        [IO.Directory]::CreateDirectory($temporaryDirectory) | Out-Null
        [IO.Directory]::CreateDirectory($output) | Out-Null
        foreach ($plan in $plans) {
            $temporary = Join-Path $temporaryDirectory ([IO.Path]::GetFileName($plan.Output))
            $arguments = @{ ContentArchive = $plan.Source; ModuleAssembly = $plan.Assemblies[0].Assembly; AdditionalAssemblies = @($plan.Assemblies | Select-Object -Skip 1 | ForEach-Object Assembly); OutputArchive = $temporary }
            if ($plan.Manifest) { $arguments.ModuleManifest = Join-Path $root $plan.Manifest }
            & $packer @arguments | Out-Null
            # Keep only assemblies supplied by this source build; original archives may contain stale or unrelated DLLs.
            $allowed = @($plan.Assemblies | ForEach-Object { [IO.Path]::GetFileName($_.Assembly) })
            $packedZip = [IO.Compression.ZipFile]::Open($temporary, [IO.Compression.ZipArchiveMode]::Update)
            try {
                foreach ($entry in @($packedZip.Entries)) {
                    if ($entry.FullName.EndsWith('.dll', [StringComparison]::OrdinalIgnoreCase) -and $entry.FullName -notin $allowed) { $entry.Delete() }
                }
            }
            finally { $packedZip.Dispose() }
            Verify-PackedAssemblies $temporary $plan.Assemblies
            [IO.File]::Move($temporary, $plan.Output, $true)
        }
        foreach ($plan in $rebuiltPlans) {
            $temporary = Join-Path $temporaryDirectory ([IO.Path]::GetFileName($plan.Output) + '.next')
            $created = $false
            try {
                $sourceStream = [IO.File]::OpenRead($plan.Prepared)
                try {
                    $targetStream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
                    $created = $true
                    try { $sourceStream.CopyTo($targetStream) } finally { $targetStream.Dispose() }
                }
                finally { $sourceStream.Dispose() }
                if ((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant() -cne $plan.ArchiveSha256) { throw 'Rebuilt package copy changed before publication.' }
                [IO.File]::Move($temporary, $plan.Output, $true)
                $created = $false
            }
            finally { if ($created -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
        }
        if (-not $SkipContentOnly) {
            foreach ($archive in $contentArchives) {
                $destination = Join-Path $output ([IO.Path]::GetFileName($archive.Path))
                if ([string]::Equals($archive.Path, $destination, [StringComparison]::OrdinalIgnoreCase)) { continue }
                Copy-Item -LiteralPath $archive.Path -Destination $destination -Force
                if ((Get-FileHash -LiteralPath $archive.Path -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash) { throw "Content archive copy differs: $($archive.Path)" }
            }
        }
    }
    $report = [ordered]@{
        status = if ($PlanOnly) { 'plan' } else { 'pass' }
        modules = @(
            $plans | ForEach-Object { [ordered]@{ name = $_.Name; archive = [IO.Path]::GetFileName($_.Source); assemblies = @($_.Assemblies | ForEach-Object { [IO.Path]::GetFileName($_.Assembly) }); manifest = $_.Manifest } }
            $rebuiltPlans | ForEach-Object { [ordered]@{ name = $_.Name; version = $_.Version; archive = [IO.Path]::GetFileName($_.Output); assemblies = @($_.AssemblyFileName); sourceKind = 'local-rebuild'; sourceArchiveSha256 = $_.SourceArchiveSha256; archiveSha256 = $_.ArchiveSha256; assemblySha256 = $_.AssemblySha256 } }
        )
        missingOriginalArchives = @($missing)
        unavailableModules = @($unavailable)
        contentArchives = @(if (-not $SkipContentOnly) { $contentArchives | ForEach-Object { [IO.Path]::GetFileName($_.Path) } })
        skippedCodeArchives = $unsupported
    }
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($reportFile)) | Out-Null
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportFile -Encoding utf8
    [pscustomobject]@{ Status = $report.status; PortedModules = ($plans.Count + $rebuiltPlans.Count); MissingOriginalArchives = $missing.Count; UnavailableModules = $unavailable.Count; ContentArchives = $report.contentArchives.Count; SkippedCodeArchives = $unsupported.Count; Report = $reportFile } | ConvertTo-Json -Compress
}
catch {
    $failure = $_
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($reportFile)) | Out-Null
    @{ status = 'failed'; message = $failure.Exception.Message; partialInstallationPossible = $publicationStarted } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $reportFile -Encoding utf8
    throw
}
