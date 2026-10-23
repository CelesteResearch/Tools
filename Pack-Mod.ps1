param(
    [Parameter(Mandatory)][string]$ContentArchive,
    [Parameter(Mandatory)][string]$ModuleAssembly,
    [string[]]$AdditionalAssemblies = @(),
    [Parameter(Mandatory)][string]$OutputArchive,
    [string]$ModuleManifest,
    [AllowEmptyCollection()][string[]]$ContentIncludes
)

$ErrorActionPreference = 'Stop'
$sourcePath = (Resolve-Path -LiteralPath $ContentArchive).Path
$assemblyPaths = @(@($ModuleAssembly) + $AdditionalAssemblies | ForEach-Object {
        (Resolve-Path -LiteralPath $_).Path
    })
$outputPath = [IO.Path]::GetFullPath($OutputArchive)
if ([string]::Equals($sourcePath, $outputPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The original content archive cannot be overwritten.'
}
$outputDirectory = [IO.Path]::GetDirectoryName($outputPath)
[IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
$temporaryPath = $outputPath + '.next'
$source = [IO.Compression.ZipFile]::OpenRead($sourcePath)
$temporaryCreated = $false
try {
    $manifestEntry = $source.GetEntry('everest.yaml')
    if ($null -eq $manifestEntry) { throw 'The content archive has no everest.yaml.' }
    $reader = [IO.StreamReader]::new($manifestEntry.Open())
    try { $manifest = $reader.ReadToEnd() } finally { $reader.Dispose() }
    $dllPattern = '(?m)^(\s+DLL:\s*)([^\r\n]+)'
    $moduleDllMatches = [regex]::Matches($manifest, $dllPattern)
    if ($moduleDllMatches.Count -ne 1) { throw 'This packer requires one module DLL declaration.' }
    $originalDll = $moduleDllMatches[0].Groups[2].Value.Trim().Trim('"', "'").Replace('\', '/')
    if ($ModuleManifest) {
        $manifestPath = (Resolve-Path -LiteralPath $ModuleManifest).Path
        $manifest = [IO.File]::ReadAllText($manifestPath)
        if ([regex]::Matches($manifest, $dllPattern).Count -ne 1) {
            throw 'The explicit module manifest requires one module DLL declaration.'
        }
    }
    $includedContent = $null
    if ($PSBoundParameters.ContainsKey('ContentIncludes')) {
        $includedContent = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($path in $ContentIncludes) {
            $entryName = $path.Replace('\', '/')
            if ($null -eq $source.GetEntry($entryName)) { throw "The included content entry does not exist: $entryName" }
            [void]$includedContent.Add($entryName)
        }
    }
    $moduleName = [IO.Path]::GetFileName($assemblyPaths[0])
    $manifest = [regex]::Replace($manifest, $dllPattern, '${1}' + $moduleName)
    $replaced = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$replaced.Add('everest.yaml')
    [void]$replaced.Add($originalDll)
    [void]$replaced.Add([IO.Path]::ChangeExtension($originalDll, '.pdb'))
    foreach ($path in $assemblyPaths) {
        if ([IO.Path]::GetExtension($path) -ine '.dll') { throw 'Only compiled DLL inputs are accepted.' }
        [void]$replaced.Add([IO.Path]::GetFileName($path))
        [void]$replaced.Add([IO.Path]::GetFileName([IO.Path]::ChangeExtension($path, '.pdb')))
    }

    $stream = [IO.File]::Open($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
    $temporaryCreated = $true
    $package = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($entry in $source.Entries) {
            if ($replaced.Contains($entry.FullName)) { continue }
            if ($null -ne $includedContent -and !$includedContent.Contains($entry.FullName)) { continue }
            $target = $package.CreateEntry($entry.FullName, [IO.Compression.CompressionLevel]::Optimal)
            $target.LastWriteTime = $entry.LastWriteTime
            $entryInputStream = $entry.Open()
            $output = $target.Open()
            try { $entryInputStream.CopyTo($output) } finally { $output.Dispose(); $entryInputStream.Dispose() }
        }
        $entry = $package.CreateEntry('everest.yaml')
        $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
        try { $writer.Write($manifest) } finally { $writer.Dispose() }
        foreach ($path in $assemblyPaths) {
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($package, $path,
                [IO.Path]::GetFileName($path), [IO.Compression.CompressionLevel]::Optimal) | Out-Null
            $symbols = [IO.Path]::ChangeExtension($path, '.pdb')
            if ([IO.File]::Exists($symbols)) {
                [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($package, $symbols,
                    [IO.Path]::GetFileName($symbols), [IO.Compression.CompressionLevel]::Optimal) | Out-Null
            }
        }
    }
    finally { $package.Dispose(); $stream.Dispose() }
    [IO.File]::Move($temporaryPath, $outputPath, $true)
    $temporaryCreated = $false
    Write-Output $outputPath
}
finally {
    $source.Dispose()
    if ($temporaryCreated) { [IO.File]::Delete($temporaryPath) }
}
