# Locked local Mod reconstruction helpers.

function Get-RecipeSha([byte[]]$Bytes) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-RecipeFileSha([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant() }
    finally { $stream.Dispose() }
}

function Get-RecipePath([string]$Root, [string]$Relative) {
    if (-not $Relative -or $Relative.Contains('\') -or [IO.Path]::IsPathRooted($Relative) -or
        @($Relative.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count) {
        throw "Invalid relative recipe path: $Relative"
    }
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $path = [IO.Path]::GetFullPath([IO.Path]::Combine($rootPath, $Relative))
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $path.StartsWith($rootPath + [IO.Path]::DirectorySeparatorChar, $comparison)) { throw 'Recipe path escaped its root.' }
    # Reject source/output symlink ancestors rather than following an alternate boundary.
    $cursor = $path
    while ($cursor -and $cursor -ne $rootPath) {
        if ([IO.File]::Exists($cursor) -or [IO.Directory]::Exists($cursor)) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Recipe path contains a symbolic link: $cursor"
            }
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    $path
}

function Read-RecipeFile([string]$Root, [string]$Path, [string]$Sha256, [switch]$HashOnly) {
    if ($Sha256 -cnotmatch '^[0-9a-f]{64}$') { throw "Invalid SHA256 for $Path" }
    $fullPath = Get-RecipePath $Root $Path
    if ((Get-RecipeFileSha $fullPath) -cne $Sha256) { throw "Input version/hash mismatch: $Path" }
    $bytes = if (-not $HashOnly) { [IO.File]::ReadAllBytes($fullPath) } else { $null }
    [pscustomobject]@{ Path = $fullPath; Sha256 = $Sha256; Bytes = $bytes }
}

function Invoke-RecipeConverter {
    param($Converter, [string]$Assembly, [string]$InputRoot, [string]$RecipePath, [string]$OutputRoot, [switch]$Check)
    if (-not [IO.File]::Exists($Assembly)) { throw 'The locally built trusted source converter is missing.' }
    $start = [Diagnostics.ProcessStartInfo]::new('dotnet')
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @($Assembly, '--input-root', $InputRoot, '--recipe', $RecipePath, '--output-root', $OutputRoot)) {
        $start.ArgumentList.Add($argument)
    }
    if ($Check) { $start.ArgumentList.Add('--check') }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) { $process.Kill($true); throw 'Source converter exceeded its time limit.' }
        if ($process.ExitCode -ne 0) { throw "Source conversion failed: $($stderr.GetAwaiter().GetResult())" }
        $report = $stdout.GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
        $expected = @($Converter.outputs)
        if (@($report.outputs).Count -ne $expected.Count) { throw 'Unexpected converter output count.' }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($output in $report.outputs) {
            if (-not $seen.Add($output.path)) { throw 'Duplicate converter output.' }
            $match = @($expected | Where-Object { $_.path -ceq $output.path -and $_.sha256 -ceq $output.sha256 })
            if ($match.Count -ne 1) { throw 'Converter output report differs from the recipe lock.' }
        }
    }
    finally { $process.Dispose() }
}

function Get-LockedModRecipePlanCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RecipeLock,
        [Parameter(Mandatory)][string]$ExpectedLockSha256,
        [Parameter(Mandatory)][string]$SourceModsDirectory,
        [Parameter(Mandatory)][string]$SourceCodeDirectory,
        [Parameter(Mandatory)][string]$RecipeDirectory,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string]$ConverterAssembly
    )
    $lockBytes = [IO.File]::ReadAllBytes($RecipeLock)
    if ((Get-RecipeSha $lockBytes) -cne $ExpectedLockSha256) { throw 'Recipe lock hash mismatch.' }
    $lockText = [Text.Encoding]::UTF8.GetString($lockBytes)
    if (-not (Test-Json -Json $lockText -SchemaFile (Join-Path $PSScriptRoot 'recipe-lock.schema.json') -ErrorAction Stop)) { throw 'Invalid recipe lock schema.' }
    $lock = $lockText | ConvertFrom-Json -AsHashtable
    if ($lock.schemaVersion -ne 1 -or -not $lock.modules.Count) { throw 'Unsupported or empty recipe lock.' }
    $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
    $inputs = [Collections.Generic.List[object]]::new()
    $modules = [ordered]@{}
    $outputRoot = Get-RecipePath $RepositoryRoot "artifacts/local-mod-recipes/$ExpectedLockSha256/$([Guid]::NewGuid().ToString('N'))"
    foreach ($module in $lock.modules) {
        if ($module.id -cnotmatch '^[A-Za-z][A-Za-z0-9._-]*$' -or $modules.Contains($module.id)) { throw 'Invalid or duplicate module id.' }
        if (-not $module.version -or $module.completeModule -ne $true) { throw "Recipe is not a complete module: $($module.id)" }
        $archive = Read-RecipeFile -Root $SourceModsDirectory -Path $module.archive.path -Sha256 $module.archive.sha256 -HashOnly
        $inputs.Add($archive)
        $content = [Collections.Generic.List[string]]::new()
        $zip = [IO.Compression.ZipFile]::OpenRead($archive.Path)
        try {
            $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($entry in $zip.Entries) {
                if ($entry.FullName.EndsWith('/')) { continue }
                [void](Get-RecipePath $SourceModsDirectory $entry.FullName)
                if (-not $names.Add($entry.FullName)) { throw 'Ambiguous duplicate archive entries.' }
                if ([IO.Path]::GetExtension($entry.FullName) -notin @('.dll', '.pdb')) { $content.Add($entry.FullName) }
            }
            if (-not $names.Contains('everest.yaml')) { throw 'Missing original module manifest.' }
        }
        finally { $zip.Dispose() }
        $files = [ordered]@{}
        $converter = $null
        $recipePath = $null
        if ($module.ContainsKey('converter')) {
            $converter = $module.converter
            $recipeFile = Read-RecipeFile -Root $RecipeDirectory -Path $converter.recipe -Sha256 $converter.sha256
            $inputs.Add($recipeFile)
            $recipePath = $recipeFile.Path
            foreach ($converterInput in $converter.inputs) {
                $inputs.Add((Read-RecipeFile -Root $SourceCodeDirectory -Path $converterInput.path -Sha256 $converterInput.sha256))
            }
            foreach ($converterOutput in $converter.outputs) {
                [void](Get-RecipePath $RepositoryRoot $converterOutput.path)
                if ($files.Contains($converterOutput.path)) { throw 'Duplicate converter output path.' }
                $files[$converterOutput.path] = $null
            }
        }
        foreach ($file in $module.files) {
            if ($files.Contains($file.output)) { throw 'Duplicate generated output.' }
            [void](Get-RecipePath $RepositoryRoot $file.output)
            $inputRoot = if ($file.origin -eq 'source') { $SourceCodeDirectory } elseif ($file.origin -eq 'recipe') { $RecipeDirectory } else { throw 'Unknown file origin.' }
            $inputFile = Read-RecipeFile -Root $inputRoot -Path $file.path -Sha256 $file.sha256
            $inputs.Add($inputFile)
            $text = $strictUtf8.GetString($inputFile.Bytes)
            foreach ($step in $file.steps) {
                if ($step.kind -ne 'replaceExact' -or -not $step.before -or $step.count -lt 1) { throw 'Unsupported exact transformation.' }
                $count = 0; $index = 0
                while (($index = $text.IndexOf($step.before, $index, [StringComparison]::Ordinal)) -ge 0) { $count++; $index += $step.before.Length }
                if ($count -ne $step.count) { throw "Unexpected exact selector count: $($file.path)" }
                $text = $text.Replace($step.before, $step.after, [StringComparison]::Ordinal)
            }
            $bytes = $strictUtf8.GetBytes($text)
            if ((Get-RecipeSha $bytes) -cne $file.outputSha256) { throw "Generated source hash mismatch: $($file.output)" }
            $files[$file.output] = $bytes
        }
        if (-not $files.Contains($module.project)) { throw 'Project template is not a locked output.' }
        [void](Get-RecipePath $RepositoryRoot $module.assembly)
        $modules[$module.id] = [pscustomobject]@{ Id = $module.id; Version = $module.version; Archive = $archive.Path; ContentIncludes = $content.ToArray(); Files = $files; Project = $module.project; Assembly = $module.assembly; Dependencies = @($module.dependencies); Converter = $converter; RecipePath = $recipePath }
    }
    $orderedModules = [Collections.Generic.List[object]]::new()
    $visiting = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    function Resolve-RecipeModuleOrder([string]$Id) {
        if (-not $modules.Contains($Id)) { throw "Missing rebuilt dependency: $Id" }
        if ($visited.Contains($Id)) { return }
        if (-not $visiting.Add($Id)) { throw "Dependency cycle: $Id" }
        foreach ($dependency in $modules[$Id].Dependencies) { Resolve-RecipeModuleOrder $dependency }
        [void]$visiting.Remove($Id); [void]$visited.Add($Id)
        $orderedModules.Add($modules[$Id])
    }
    foreach ($id in $modules.Keys) { Resolve-RecipeModuleOrder $id }
    foreach ($module in $orderedModules) {
        if ($module.Converter) {
            Invoke-RecipeConverter -Converter $module.Converter -Assembly $ConverterAssembly -InputRoot $SourceCodeDirectory -RecipePath $module.RecipePath -OutputRoot (Get-RecipePath $outputRoot $module.Id) -Check
        }
    }
    $converterSha = if ($ConverterAssembly) { Get-RecipeSha ([IO.File]::ReadAllBytes($ConverterAssembly)) } else { $null }
    [pscustomobject]@{ LockPath = [IO.Path]::GetFullPath($RecipeLock); LockSha256 = $ExpectedLockSha256; RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot); OutputRoot = $outputRoot; Inputs = $inputs.ToArray(); Modules = $orderedModules.ToArray(); ConverterAssembly = $ConverterAssembly; ConverterSha256 = $converterSha; SourceCodeDirectory = [IO.Path]::GetFullPath($SourceCodeDirectory) }
}

function Invoke-LockedModRecipeBuildAndPack {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$PackModScript,
        # Internal fixture injection only; never loaded from a recipe/user configuration.
        [scriptblock]$BuildInvoker
    )
    Set-StrictMode -Version Latest
    try {
        if ((Get-RecipeSha ([IO.File]::ReadAllBytes($Plan.LockPath))) -cne $Plan.LockSha256) { throw 'Recipe lock changed after preflight.' }
        foreach ($inputFile in $Plan.Inputs) {
            if ((Get-RecipeFileSha $inputFile.Path) -cne $inputFile.Sha256) { throw 'Original input changed after preflight.' }
        }
        if ($Plan.ConverterAssembly -and (Get-RecipeSha ([IO.File]::ReadAllBytes($Plan.ConverterAssembly))) -cne $Plan.ConverterSha256) { throw 'Converter changed after preflight.' }
        if (Test-Path -LiteralPath $Plan.OutputRoot) { throw 'Recipe output already exists; refusing to merge with an earlier build.' }
        foreach ($module in $Plan.Modules) {
            $moduleRoot = Get-RecipePath $Plan.OutputRoot $module.Id
            if ($module.Converter) {
                Invoke-RecipeConverter -Converter $module.Converter -Assembly $Plan.ConverterAssembly -InputRoot $Plan.SourceCodeDirectory -RecipePath $module.RecipePath -OutputRoot $moduleRoot
                $actualFiles = @(Get-ChildItem -LiteralPath $moduleRoot -File -Recurse -Force)
                if ($actualFiles.Count -ne $module.Converter.outputs.Count) { throw 'Converter wrote an unlisted file.' }
                foreach ($output in $module.Converter.outputs) {
                    [void](Read-RecipeFile -Root $moduleRoot -Path $output.path -Sha256 $output.sha256)
                }
            }
            foreach ($entry in $module.Files.GetEnumerator()) {
                if ($null -eq $entry.Value) { continue }
                $path = Get-RecipePath $moduleRoot $entry.Key
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
                [IO.File]::WriteAllBytes($path, $entry.Value)
            }
        }
        $packages = [Collections.Generic.List[object]]::new()
        foreach ($module in $Plan.Modules) {
            $moduleRoot = Get-RecipePath $Plan.OutputRoot $module.Id
            $project = Get-RecipePath $moduleRoot $module.Project
            $assembly = Get-RecipePath $moduleRoot $module.Assembly
            if ($BuildInvoker) { & $BuildInvoker $module $project $assembly }
            else {
                & dotnet build $project -c Release --nologo -v minimal -m:1 -nodeReuse:false '-p:UseSharedCompilation=false' '-p:BuildProjectReferences=false' "-p:SharedRoot=$($Plan.RepositoryRoot)/Shared" "-p:RecipeRoot=$($Plan.OutputRoot)" | Out-Host
                if ($LASTEXITCODE -ne 0) { throw "Rebuilt module failed: $($module.Id)" }
            }
            if (-not [IO.File]::Exists($assembly)) { throw "Missing rebuilt module assembly: $($module.Id)" }
            $assemblySha = Get-RecipeSha ([IO.File]::ReadAllBytes($assembly))
            $outputArchive = Get-RecipePath $Plan.OutputRoot "packages/$($module.Id).zip"
            $archiveInput = @($Plan.Inputs | Where-Object { $_.Path -ceq $module.Archive })[0]
            if ((Get-RecipeFileSha $module.Archive) -cne $archiveInput.Sha256) { throw 'Original archive changed during the build.' }
            & $PackModScript -ContentArchive $module.Archive -ModuleAssembly $assembly -OutputArchive $outputArchive -ContentIncludes $module.ContentIncludes | Out-Null
            $zip = [IO.Compression.ZipFile]::OpenRead($outputArchive)
            try {
                $entry = $zip.GetEntry([IO.Path]::GetFileName($assembly))
                if ($null -eq $entry) { throw 'Packed module assembly is absent.' }
                $stream = $entry.Open(); $buffer = [IO.MemoryStream]::new()
                try { $stream.CopyTo($buffer); if ((Get-RecipeSha $buffer.ToArray()) -cne $assemblySha) { throw 'Packed assembly hash mismatch.' } }
                finally { $stream.Dispose(); $buffer.Dispose() }
            }
            finally { $zip.Dispose() }
            $packages.Add([pscustomobject]@{ Id = $module.Id; Version = $module.Version; AssemblySha256 = $assemblySha; Archive = $outputArchive; ArchiveSha256 = Get-RecipeSha ([IO.File]::ReadAllBytes($outputArchive)) })
        }
        $packages.ToArray()
    }
    finally {
        if ($Plan.PSObject.Properties['ScratchRoot'] -and $Plan.ScratchRoot) { Remove-RecipeScratch -Path $Plan.ScratchRoot -RepositoryRoot $Plan.RepositoryRoot }
    }
}


function Remove-RecipeScratch {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path, [string]$RepositoryRoot)
    $parent = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'artifacts/local-mod-inputs')).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $target = [IO.Path]::GetFullPath($Path)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $target.StartsWith($parent + [IO.Path]::DirectorySeparatorChar, $comparison) -or [IO.Path]::GetDirectoryName($target) -cne $parent) { throw 'Invalid scratch cleanup boundary.' }
    if ($PSCmdlet.ShouldProcess($target, 'Delete this invocation temporary decompilation inputs')) {
        if ([IO.Directory]::Exists($target)) { [IO.Directory]::Delete($target, $true) }
        if (Test-Path -LiteralPath $target) { throw 'Scratch cleanup did not complete.' }
    }
}

function Get-LockedModRecipePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RecipeLock,
        [Parameter(Mandatory)][string]$ExpectedLockSha256,
        [Parameter(Mandatory)][string]$SourceModsDirectory,
        [Parameter(Mandatory)][string]$SourceCodeDirectory,
        [Parameter(Mandatory)][string]$RecipeDirectory,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string]$ConverterAssembly,
        [string]$DecompilerDirectory,
        [string]$ReferenceDirectory
    )
    Set-StrictMode -Version Latest
    if ((Get-RecipeFileSha $RecipeLock) -cne $ExpectedLockSha256) { throw 'Recipe lock hash mismatch.' }
    $text = [IO.File]::ReadAllText($RecipeLock)
    if (-not (Test-Json -Json $text -SchemaFile (Join-Path $PSScriptRoot 'recipe-lock.schema.json') -ErrorAction Stop)) { throw 'Invalid recipe lock schema.' }
    $lock = $text | ConvertFrom-Json -AsHashtable
    $scratch = $null
    try {
        $originalInputs = @()
        if (@($lock.modules | Where-Object { $_.ContainsKey('decompile') -or $_.ContainsKey('archiveSources') }).Count -gt 0) {
            . (Join-Path $PSScriptRoot 'RecipeDecompilation.ps1')
            $decompiled = Get-RecipeDecompiledInput -Lock $lock -SourceModsDirectory $SourceModsDirectory -DecompilerDirectory $DecompilerDirectory -ReferenceDirectory $ReferenceDirectory -RepositoryRoot $RepositoryRoot
            $scratch = $decompiled.ScratchRoot
            $SourceCodeDirectory = $decompiled.InputRoot
            $originalInputs = $decompiled.Inputs
        }
        $plan = Get-LockedModRecipePlanCore -RecipeLock $RecipeLock -ExpectedLockSha256 $ExpectedLockSha256 -SourceModsDirectory $SourceModsDirectory -SourceCodeDirectory $SourceCodeDirectory -RecipeDirectory $RecipeDirectory -RepositoryRoot $RepositoryRoot -ConverterAssembly $ConverterAssembly
        $plan.Inputs = @($plan.Inputs) + @($originalInputs)
        $plan | Add-Member -NotePropertyName ScratchRoot -NotePropertyValue $scratch
        $plan
    }
    catch {
        if ($scratch) { Remove-RecipeScratch -Path $scratch -RepositoryRoot $RepositoryRoot }
        throw
    }
}
