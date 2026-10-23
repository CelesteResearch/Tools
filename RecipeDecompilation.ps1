# Reference variants are parser data, never loaded as executable assemblies.
function Get-RecipeReferenceIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    Add-Type -AssemblyName System.Reflection.Metadata
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $pe = $null
    try {
        $pe = [Reflection.PortableExecutable.PEReader]::new($stream)
        if (-not $pe.HasMetadata) { throw 'Reference has no managed metadata.' }
        $metadata = [Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($pe)
        if (-not $metadata.IsAssembly) { throw 'Reference is not an assembly definition.' }
        $definition = $metadata.GetAssemblyDefinition()
        $identity = [Reflection.AssemblyName]::new()
        $identity.Name = $metadata.GetString($definition.Name)
        $identity.Version = $definition.Version
        $identity.CultureName = if ($definition.Culture.IsNil) { '' } else { $metadata.GetString($definition.Culture) }
        if (-not $definition.PublicKey.IsNil) { $identity.SetPublicKey($metadata.GetBlobBytes($definition.PublicKey)) }
        else { $identity.SetPublicKeyToken([byte[]]@()) }
        $identity.FullName
    }
    finally {
        if ($null -ne $pe) { $pe.Dispose() }
        $stream.Dispose()
    }
}

function Read-RecipeReference {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReferenceDirectory,
        [Parameter(Mandatory)][Collections.IDictionary]$Reference
    )
    $hasRawLock = $Reference.Contains('sha256')
    $hasIdentityLock = $Reference.Contains('assemblyIdentity')
    if ($hasRawLock -eq $hasIdentityLock) { throw 'Reference requires exactly one raw hash or assembly identity lock.' }
    if ($hasRawLock) {
        return Read-RecipeFile $ReferenceDirectory $Reference.path $Reference.sha256 -HashOnly
    }
    if ([string]::IsNullOrWhiteSpace($Reference.assemblyIdentity)) { throw 'Reference identity lock is empty.' }
    $path = Get-RecipePath $ReferenceDirectory $Reference.path
    $observedSha = Get-RecipeFileSha $path
    $inputFile = Read-RecipeFile $ReferenceDirectory $Reference.path $observedSha -HashOnly
    if ((Get-RecipeReferenceIdentity -Path $inputFile.Path) -cne $Reference.assemblyIdentity) {
        throw 'Reference assembly identity is unsupported.'
    }
    if ((Get-RecipeFileSha $inputFile.Path) -cne $inputFile.Sha256) { throw 'Reference changed during identity verification.' }
    # The observed raw bytes become this transaction's immutable Plan.Inputs hash.
    # Fixed canonical full-source and converted-output hashes remain the acceptance gates.
    $inputFile
}

# Pinned ILSpy preparation. No original installation files are modified.
function Get-RecipeDecompiledInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Lock,
        [Parameter(Mandatory)][string]$SourceModsDirectory,
        [string]$DecompilerDirectory,
        [string]$ReferenceDirectory,
        [Parameter(Mandatory)][string]$RepositoryRoot
    )
    $inputs = [Collections.Generic.List[object]]::new()
    $references = [Collections.Generic.List[object]]::new()
    $archiveSourceFiles = [Collections.Generic.List[object]]::new()
    $needsDecompiler = @($Lock.modules | Where-Object { $_.ContainsKey('decompile') }).Count -gt 0
    if ($needsDecompiler) {
        if ($Lock.decompiler.toolVersion -cne '10.1.0.8386') { throw 'Unsupported locked decompiler version.' }
        $toolPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($toolFile in $Lock.decompiler.toolFiles) {
            $inputFile = Read-RecipeFile $DecompilerDirectory $toolFile.path $toolFile.sha256 -HashOnly
            if (-not $toolPaths.Add($inputFile.Path)) { throw 'Duplicate tool input.' }
            $inputs.Add($inputFile)
        }
        $toolEntry = Get-RecipePath $DecompilerDirectory $Lock.decompiler.entrypoint
        if (-not $toolPaths.Contains($toolEntry)) { throw 'ILSpy entrypoint is not hash locked.' }
        foreach ($actual in Get-ChildItem -LiteralPath $DecompilerDirectory -File -Recurse -Force) {
            if ($actual.Extension -in @('.dll', '.json', '.exe', '.so', '.dylib') -and
                -not $toolPaths.Contains($actual.FullName)) { throw 'An unpinned runtime file exists in the decompiler tool graph.' }
        }
        $referenceNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        if ($Lock.decompiler.Contains('frameworkReferences')) {
            foreach ($reference in $Lock.decompiler.frameworkReferences) {
                $inputFile = Read-RecipeFile $DecompilerDirectory $reference.path $reference.sha256 -HashOnly
                if (-not $toolPaths.Contains($inputFile.Path)) { throw 'Framework reference is not in the locked tool graph.' }
                if (-not $referenceNames.Add([IO.Path]::GetFileName($inputFile.Path))) { throw 'Ambiguous framework reference basename.' }
                $references.Add($inputFile)
            }
        }
        foreach ($reference in $Lock.decompiler.references) {
            $inputFile = Read-RecipeReference -ReferenceDirectory $ReferenceDirectory -Reference $reference
            if (-not $referenceNames.Add([IO.Path]::GetFileName($inputFile.Path))) { throw 'Ambiguous reference assembly basename.' }
            $references.Add($inputFile)
            $inputs.Add($inputFile)
        }
    }
    $assemblies = [Collections.Generic.List[object]]::new()
    $outputs = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($module in $Lock.modules) {
        $usesArchiveSources = $module.ContainsKey('archiveSources')
        if ($usesArchiveSources -eq $module.ContainsKey('decompile')) { throw 'Each module must declare exactly one original source strategy.' }
        $archive = Read-RecipeFile $SourceModsDirectory $module.archive.path $module.archive.sha256 -HashOnly
        $inputs.Add($archive)
        $zip = [IO.Compression.ZipFile]::OpenRead($archive.Path)
        try {
            if ($usesArchiveSources) {
                if ($module.ContainsKey('originalAssembly')) {
                    $originalEntries = @($zip.Entries | Where-Object FullName -CEQ $module.originalAssembly.entry)
                    if ($originalEntries.Count -ne 1) { throw 'The original Mod assembly is absent or duplicated.' }
                    $originalStream = $originalEntries[0].Open()
                    try { $originalSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($originalStream)).ToLowerInvariant() }
                    finally { $originalStream.Dispose() }
                    if ($originalSha -cne $module.originalAssembly.sha256) { throw 'The original Mod assembly hash differs.' }
                }
                foreach ($source in $module.archiveSources) {
                    [void](Get-RecipePath $RepositoryRoot $source.entry)
                    [void](Get-RecipePath $RepositoryRoot $source.path)
                    if (-not $outputs.Add($source.path)) { throw 'Duplicate prepared source path.' }
                    $sourceEntries = @($zip.Entries | Where-Object FullName -CEQ $source.entry)
                    if ($sourceEntries.Count -ne 1 -or $sourceEntries[0].Length -gt 16MB -or [IO.Path]::GetExtension($source.entry) -cne '.cs') { throw 'A locked original C# ZIP entry is absent, duplicated or invalid.' }
                    $sourceStream = $sourceEntries[0].Open()
                    $sourceBuffer = [IO.MemoryStream]::new()
                    try { $sourceStream.CopyTo($sourceBuffer); $sourceBytes = $sourceBuffer.ToArray() }
                    finally { $sourceStream.Dispose(); $sourceBuffer.Dispose() }
                    $sourceText = [Text.UTF8Encoding]::new($false, $true).GetString($sourceBytes).TrimStart([char]0xFEFF).Replace("`r`n", "`n").Replace("`r", "`n")
                    $canonicalBytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($sourceText)
                    if ((Get-RecipeSha $canonicalBytes) -cne $source.sha256) { throw 'Canonical original ZIP source differs from its locked hash.' }
                    $archiveSourceFiles.Add([pscustomobject]@{ Path = $source.path; Bytes = $canonicalBytes })
                }
                continue
            }
            $assemblyEntries = @($zip.Entries | Where-Object FullName -CEQ $module.decompile.assemblyEntry)
            if ($assemblyEntries.Count -ne 1) { throw 'Locked Mod DLL entry is absent or duplicated.' }
            $entry = $assemblyEntries[0]
            if ([IO.Path]::GetExtension($entry.FullName) -ine '.dll' -or $entry.Length -gt 64MB) { throw 'Invalid or oversized original Mod DLL.' }
            $stream = $entry.Open(); $buffer = [IO.MemoryStream]::new()
            try { $stream.CopyTo($buffer); $bytes = $buffer.ToArray() }
            finally { $stream.Dispose(); $buffer.Dispose() }
            if ((Get-RecipeSha $bytes) -cne $module.decompile.assemblySha256) { throw 'Original Mod DLL hash mismatch.' }
            foreach ($type in $module.decompile.types) {
                [void](Get-RecipePath $RepositoryRoot $type.path)
                if (-not $outputs.Add($type.path)) { throw 'Duplicate decompiled source path.' }
                if ($type.name -cnotmatch '^[A-Za-z_][A-Za-z0-9_.+`]*$') { throw 'Invalid pinned CLR type name.' }
            }
            $assemblies.Add([pscustomobject]@{ Module = $module; Bytes = $bytes })
        }
        finally { $zip.Dispose() }
    }
    # Only after the complete ZIP/DLL/tool/reference graph has passed do temporary inputs get written.
    $scratch = Get-RecipePath $RepositoryRoot ('artifacts/local-mod-inputs/' + [Guid]::NewGuid().ToString('N'))
    try {
        $inputRoot = Get-RecipePath $scratch 'source'
        $referenceRoot = Get-RecipePath $scratch 'references'
        [IO.Directory]::CreateDirectory($inputRoot) | Out-Null
        foreach ($source in $archiveSourceFiles) {
            $sourcePath = Get-RecipePath $inputRoot $source.Path
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($sourcePath)) | Out-Null
            [IO.File]::WriteAllBytes($sourcePath, $source.Bytes)
        }
        if ($needsDecompiler) { [IO.Directory]::CreateDirectory($referenceRoot) | Out-Null }
        foreach ($reference in $references) {
            $destination = Get-RecipePath $referenceRoot ([IO.Path]::GetFileName($reference.Path))
            [IO.File]::Copy($reference.Path, $destination, $false)
            if ((Get-RecipeFileSha $destination) -cne $reference.Sha256) { throw 'Reference changed during preparation.' }
        }
        foreach ($assembly in $assemblies) {
            $assemblyPath = Get-RecipePath $scratch ("assemblies/$($assembly.Module.id).dll")
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($assemblyPath)) | Out-Null
            [IO.File]::WriteAllBytes($assemblyPath, $assembly.Bytes)
            foreach ($type in $assembly.Module.decompile.types) {
                $start = [Diagnostics.ProcessStartInfo]::new('dotnet')
                $start.UseShellExecute = $false
                $start.RedirectStandardOutput = $true
                $start.RedirectStandardError = $true
                $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false, $true)
                foreach ($argument in @($toolEntry, '--disable-updatecheck', '-lv', 'CSharp13_0', '-t', $type.name, '-r', $referenceRoot, $assemblyPath)) { $start.ArgumentList.Add($argument) }
                $process = [Diagnostics.Process]::Start($start)
                try {
                    $stdout = $process.StandardOutput.ReadToEndAsync()
                    $stderr = $process.StandardError.ReadToEndAsync()
                    if (-not $process.WaitForExit(120000)) { $process.Kill($true); throw 'Pinned decompilation exceeded its time limit.' }
                    [void]$stderr.GetAwaiter().GetResult()
                    if ($process.ExitCode -ne 0) { throw "Pinned decompilation failed for type $($type.name)." }
                    $text = $stdout.GetAwaiter().GetResult().TrimStart([char]0xFEFF).Replace("`r`n", "`n").Replace("`r", "`n")
                }
                finally { $process.Dispose() }
                $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($text)
                if ((Get-RecipeSha $bytes) -cne $type.sha256) { throw "Canonical decompiled source mismatch for type $($type.name)." }
                $path = Get-RecipePath $inputRoot $type.path
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
                [IO.File]::WriteAllBytes($path, $bytes)
            }
        }
        [pscustomobject]@{ ScratchRoot = $scratch; InputRoot = $inputRoot; Inputs = $inputs.ToArray() }
    }
    catch { Remove-RecipeScratch -Path $scratch -RepositoryRoot $RepositoryRoot; throw }
}
