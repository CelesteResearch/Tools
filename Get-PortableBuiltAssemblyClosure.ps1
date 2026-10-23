# Query existing portable build outputs and their actual resolved dependencies.
# ResolveReferences is metadata/reference resolution only; compilation is never requested.
param(
    [Parameter(Mandatory)][string]$SharedRoot,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Release'
)
$ErrorActionPreference = 'Stop'
$sharedPath = (Resolve-Path -LiteralPath $SharedRoot).Path
$outputPath = [IO.Path]::GetFullPath($OutputDirectory)
$solutionPath = Join-Path $sharedPath 'Shared.slnx'
if (-not (Test-Path -LiteralPath $solutionPath -PathType Leaf)) { throw "Shared solution is missing: $solutionPath" }
[IO.Directory]::CreateDirectory($outputPath) | Out-Null
[xml]$solution = Get-Content -LiteralPath $solutionPath -Raw
$assemblies = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
$assemblyNames = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
$excluded = [Collections.Generic.List[object]]::new()
$projects = [Collections.Generic.List[object]]::new()

function Invoke-ReferenceQuery([string]$ProjectPath, [string]$Framework, [switch]$Resolve) {
    $arguments = @($sdkMsbuildPath, $ProjectPath, '-nologo', '-verbosity:quiet', '-nodeReuse:false',
        "-p:Configuration=$Configuration", '-p:BuildProjectReferences=false', '-p:CopyLocalLockFileAssemblies=true')
    if ($Framework) { $arguments += "-p:TargetFramework=$Framework" }
    if ($Resolve) { $arguments += @('-target:ResolveReferences', '-getProperty:TargetFramework,TargetPath,AssemblyName', '-getItem:ReferenceCopyLocalPaths') }
    else { $arguments += '-getProperty:TargetFramework,TargetFrameworks,AssemblyName,IsRoslynComponent' }
    $raw = & dotnet @arguments
    if ($LASTEXITCODE -ne 0) { throw "Reference query failed ($LASTEXITCODE): $ProjectPath" }
    return ($raw -join "`n") | ConvertFrom-Json
}

function Read-PortableAssemblyFacts([string]$Path) {
    # Read PE metadata only. Do not load game, framework or SDK assemblies for execution.
    $identity = [Reflection.AssemblyName]::GetAssemblyName($Path)
    $stream = [IO.File]::OpenRead($Path)
    $pe = [Reflection.PortableExecutable.PEReader]::new($stream)
    try {
        if (-not $pe.HasMetadata) { throw "The managed closure contains a native DLL: $Path" }
        $reader = [Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($pe)
        $framework = $null
        foreach ($handle in $reader.GetAssemblyDefinition().GetCustomAttributes()) {
            $attribute = $reader.GetCustomAttribute($handle)
            $constructor = $attribute.Constructor
            $namespace = $null; $name = $null
            if ($constructor.Kind -eq [Reflection.Metadata.HandleKind]::MemberReference) {
                $member = $reader.GetMemberReference([Reflection.Metadata.MemberReferenceHandle]$constructor)
                if ($member.Parent.Kind -eq [Reflection.Metadata.HandleKind]::TypeReference) {
                    $type = $reader.GetTypeReference([Reflection.Metadata.TypeReferenceHandle]$member.Parent)
                    $namespace = $reader.GetString($type.Namespace); $name = $reader.GetString($type.Name)
                }
            }
            elseif ($constructor.Kind -eq [Reflection.Metadata.HandleKind]::MethodDefinition) {
                $method = $reader.GetMethodDefinition([Reflection.Metadata.MethodDefinitionHandle]$constructor)
                $type = $reader.GetTypeDefinition($method.GetDeclaringType())
                $namespace = $reader.GetString($type.Namespace); $name = $reader.GetString($type.Name)
            }
            if ($namespace -eq 'System.Runtime.Versioning' -and $name -eq 'TargetFrameworkAttribute') {
                if ($null -ne $framework) { throw "Duplicate target framework attributes: $Path" }
                $blob = $reader.GetBlobReader($attribute.Value)
                if ($blob.ReadUInt16() -ne 1) { throw "Invalid framework attribute: $Path" }
                $framework = $blob.ReadSerializedString()
            }
        }
        if ($framework -and $framework -notmatch '^\.NETStandard,Version=v(1\.[0-6]|2\.[01])(,|$)|^\.NETFramework,Version=v[234]\.') {
            throw "Nonportable dependency is forbidden in the Unity package: $Path ($framework)"
        }
        $references = @(
            foreach ($handle in $reader.AssemblyReferences) {
                $reference = $reader.GetAssemblyReference($handle)
                $referenceName = $reader.GetString($reference.Name)
                if ($referenceName -eq 'System.Private.CoreLib' -or
                    ($referenceName -in @('System.Runtime', 'System.Runtime.Loader', 'netstandard') -and $reference.Version.Major -ge 5)) {
                    throw "Core runtime dependency is forbidden in the Unity portable closure: $Path -> $referenceName $($reference.Version)"
                }
                [pscustomobject]@{ Name = $referenceName; Version = $reference.Version.ToString() }
            }
        )
        return [pscustomobject]@{ Name = $identity.Name; Identity = $identity.FullName; TargetFramework = $framework; References = $references }
    }
    finally { $pe.Dispose(); $stream.Dispose() }
}

Push-Location -LiteralPath $sharedPath
try {
    # Resolve SDK selection once in the shared repository, preserving global.json
    # and its rollForward policy. Invoke that exact SDK MSBuild entry point for
    # each metadata query rather than repeating CLI post-work per project.
    $sdkVersion = (& dotnet --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $sdkVersion) { throw 'The shared repository SDK selection failed.' }
    $sdkEntries = & dotnet --list-sdks
    if ($LASTEXITCODE -ne 0) { throw 'The installed SDK inventory is unavailable.' }
    $sdkRoots = @($sdkEntries | ForEach-Object {
            if ($_ -match ('^' + [regex]::Escape($sdkVersion) + ' \[(.+)\]$')) { $Matches[1] }
        })
    if ($sdkRoots.Count -ne 1) { throw "The selected SDK must resolve to one installed SDK directory: $sdkVersion" }
    $sdkMsbuildPath = Join-Path (Join-Path $sdkRoots[0] $sdkVersion) 'MSBuild.dll'
    if (-not (Test-Path -LiteralPath $sdkMsbuildPath -PathType Leaf)) { throw "The selected SDK MSBuild entry point is missing: $sdkMsbuildPath" }
    foreach ($project in @($solution.SelectNodes('//Project'))) {
        $projectPath = [IO.Path]::GetFullPath((Join-Path $sharedPath $project.GetAttribute('Path')))
        if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) { throw "Solution project is missing: $projectPath" }
        $evaluated = Invoke-ReferenceQuery $projectPath ''
        # Compiler components remain visible/buildable in the solution, but their
        # Roslyn dependencies are not part of the game runtime publication.
        if ($evaluated.Properties.IsRoslynComponent -eq 'true') {
            $excluded.Add([pscustomobject]@{ Project = $projectPath; Reason = 'RoslynComponent' })
            continue
        }
        $frameworks = if ($evaluated.Properties.TargetFramework) { @($evaluated.Properties.TargetFramework) }
        elseif ($evaluated.Properties.TargetFrameworks) { @($evaluated.Properties.TargetFrameworks -split ';') }
        else { throw "Evaluated target framework is missing: $projectPath" }
        $portable = @($frameworks | Where-Object { $_ -in @('netstandard2.0', 'netstandard2.1') })
        if ($portable.Count -eq 0) {
            $excluded.Add([pscustomobject]@{ Project = $projectPath; Frameworks = $frameworks })
            continue
        }
        # A multitarget project contributes its highest Unity-compatible target once.
        $framework = if ('netstandard2.1' -in $portable) { 'netstandard2.1' } else { 'netstandard2.0' }
        $resolved = Invoke-ReferenceQuery $projectPath $framework -Resolve
        if ($resolved.Properties.TargetFramework -ne $framework) { throw "Resolved framework mismatch: $projectPath" }
        $targetPath = $resolved.Properties.TargetPath
        if ([string]::IsNullOrEmpty($targetPath)) { throw "Built target path is missing: $projectPath" }
        $projects.Add([pscustomobject]@{ Project = $projectPath; Framework = $framework; AssemblyName = $resolved.Properties.AssemblyName; TargetPath = $targetPath; ExcludedFrameworks = @($frameworks | Where-Object { $_ -notin @('netstandard2.0', 'netstandard2.1') }) })
        $name = [IO.Path]::GetFileNameWithoutExtension($projectPath)
        $resolved | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $outputPath "$name.references.json") -Encoding utf8
        $paths = @($targetPath) + @($resolved.Items.ReferenceCopyLocalPaths | ForEach-Object { $_.FullPath })
        foreach ($path in $paths) {
            if ([IO.Path]::GetExtension($path) -ne '.dll') { continue }
            if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path (Split-Path -Parent $projectPath) $path }
            $path = (Resolve-Path -LiteralPath $path).Path
            $fileName = [IO.Path]::GetFileName($path)
            $facts = Read-PortableAssemblyFacts $path
            if ($fileName -cne "$($facts.Name).dll") { throw "Assembly/file identity mismatch: $path ($($facts.Name))" }
            $sha = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            foreach ($table in @($assemblies, $assemblyNames)) {
                $key = if ([object]::ReferenceEquals($table, $assemblies)) { $fileName } else { $facts.Name }
                if ($table.ContainsKey($key) -and $table[$key].SHA256 -cne $sha) { throw "Conflicting built dependency bytes: $key" }
            }
            if ($assemblies.ContainsKey($fileName)) { continue }
            $entry = [pscustomobject]@{ FileName = $fileName; Path = $path; SHA256 = $sha; Identity = $facts.Identity; TargetFramework = $facts.TargetFramework; References = $facts.References; Consumer = $projectPath }
            $assemblies.Add($fileName, $entry); $assemblyNames.Add($facts.Name, $entry)
        }
        $target = Read-PortableAssemblyFacts ((Resolve-Path -LiteralPath $targetPath).Path)
        if ($target.Name -cne $resolved.Properties.AssemblyName) { throw "Built target name mismatch: $projectPath" }
    }
}
finally { Pop-Location }
if ($projects.Count -eq 0 -or $assemblies.Count -eq 0) { throw 'No actual portable build outputs were resolved.' }
$result = [pscustomobject]@{ Configuration = $Configuration; Projects = @($projects); Assemblies = @($assemblies.Values | Sort-Object FileName); ExcludedProjects = @($excluded); Compiled = $false; GameOrTasRun = $false }
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $outputPath 'PortableBuiltAssemblyClosure.json') -Encoding utf8
return $result
