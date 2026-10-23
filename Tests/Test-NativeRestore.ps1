[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$restoreScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'Restore-Native.ps1'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Platform.ps1')
$parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$directory = Join-Path $parent ('celeste-native-restore-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($directory) | Out-Null

function Write-NativeHeaderFixture([string]$Path, [string]$RuntimeIdentifier, [switch]$WrongArchitecture, [uint32]$StackFlags = 7) {
    # These fixtures exercise file discovery, architecture checks and copies, never native execution.
    $fmodElf = $RuntimeIdentifier.StartsWith('linux-') -and [IO.Path]::GetFileName($Path) -match '^libfmod(studio)?\.so(\.10(\.14)?)?$'
    $bytes = [byte[]]::new($(if ($fmodElf) { 128 } else { 64 }))
    if ($RuntimeIdentifier.StartsWith('linux-')) {
        [Array]::Copy([byte[]]@(0x7f, 0x45, 0x4c, 0x46, 2, 1), $bytes, 6)
        $bytes[6] = 1
        $bytes[16] = 3
        $bytes[18] = 62
        $bytes[20] = 1
        $bytes[52] = 64
        if ($fmodElf) {
            $bytes[32] = 64
            $bytes[54] = 56
            $bytes[56] = 1
            [Array]::Copy([BitConverter]::GetBytes([uint32]1685382481), 0, $bytes, 64, 4)
            [Array]::Copy([BitConverter]::GetBytes($StackFlags), 0, $bytes, 68, 4)
        }
        if ($WrongArchitecture) { $bytes[4] = 1 }
    }
    else {
        [Array]::Copy([byte[]]@(0xcf, 0xfa, 0xed, 0xfe, 7, 0, 0, 1), $bytes, 8)
    }
    $marker = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFileName($Path)))
    $bytes[$bytes.Length - 1] = $marker[0]
    [IO.File]::WriteAllBytes($Path, $bytes)
}

try {
    foreach ($case in @('canonical', 'versioned', 'sdk-patch-filename', 'non-executable-stack', 'wrong-architecture', 'missing-sdl', 'missing-stack-header', 'invalid-program-table', 'invalid-segment', 'duplicate-stack-header', 'mac-orig')) {
        $workspace = Join-Path $directory $case
        $game = Join-Path $workspace 'game'
        $rid = if ($case -eq 'mac-orig') { 'osx-x64' } else { 'linux-x64' }
        $nativeInput = Join-Path $game $(if ($rid -eq 'osx-x64') { 'orig/osx' } else { 'orig/lib64' })
        [IO.Directory]::CreateDirectory($nativeInput) | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $game 'Celeste.dll'), [byte[]]::new(0))
        $projectSettings = Join-Path $workspace 'Unity/ProjectSettings'
        [IO.Directory]::CreateDirectory($projectSettings) | Out-Null
        [IO.File]::WriteAllText((Join-Path $projectSettings 'ProjectVersion.txt'), 'fixture')
        $names = if ($rid -eq 'osx-x64') {
            @('libSDL2.dylib', 'libFAudio.dylib', 'libFNA3D.dylib', 'libtheorafile.dylib', 'libfmod.dylib', 'libfmodstudio.dylib', 'liblua5.4.dylib', 'libMoltenVK.dylib')
        }
        else {
            @('libSDL2.so', 'libFAudio.so', 'libFNA3D.so', 'libtheorafile.so', 'liblua5.4.so') + $(if ($case -eq 'canonical') { @('libfmod.so', 'libfmodstudio.so') } elseif ($case -eq 'sdk-patch-filename') { @('libfmod.so.10.14', 'libfmodstudio.so.10.14') } else { @('libfmod.so.10', 'libfmodstudio.so.10') })
        }
        foreach ($name in $names) {
            Write-NativeHeaderFixture (Join-Path $nativeInput $name) $rid -WrongArchitecture:($case -eq 'wrong-architecture' -and $name -eq 'libfmodstudio.so.10') -StackFlags:$(if ($case -eq 'non-executable-stack') { 6 } else { 7 })
        }
        if ($rid -eq 'linux-x64' -and $case -ne 'missing-sdl') {
            $bridgeDirectory = Join-Path $game 'everest-lib/lib64-linux'
            [IO.Directory]::CreateDirectory($bridgeDirectory) | Out-Null
            Write-NativeHeaderFixture (Join-Path $bridgeDirectory 'libfmod_SDL.so') $rid
        }
        if ($case -in @('missing-stack-header', 'invalid-program-table', 'invalid-segment', 'duplicate-stack-header')) {
            $malformedPath = Join-Path $nativeInput 'libfmod.so.10'
            $malformed = [IO.File]::ReadAllBytes($malformedPath)
            switch ($case) {
                'missing-stack-header' { [Array]::Clear($malformed, 64, 4) }
                'invalid-program-table' { [Array]::Copy([BitConverter]::GetBytes([uint64]($malformed.Length + 1)), 0, $malformed, 32, 8) }
                'invalid-segment' { [Array]::Copy([BitConverter]::GetBytes([uint64]($malformed.Length + 1)), 0, $malformed, 72, 8) }
                'duplicate-stack-header' {
                    $duplicate = [byte[]]::new(184)
                    [Array]::Copy($malformed, $duplicate, $malformed.Length)
                    [Array]::Copy($malformed, 64, $duplicate, 120, 56)
                    $duplicate[56] = 2
                    $malformed = $duplicate
                }
            }
            [IO.File]::WriteAllBytes($malformedPath, $malformed)
        }
        $sourceHashes = @{}
        foreach ($original in Get-ChildItem -LiteralPath $game -File -Recurse) { $sourceHashes[$original.FullName] = (Get-FileHash -LiteralPath $original.FullName -Algorithm SHA256).Hash }
        if ($case -in @('wrong-architecture', 'missing-sdl', 'missing-stack-header', 'invalid-program-table', 'invalid-segment', 'duplicate-stack-header')) {
            $rejected = $false
            try { & $restoreScript -CelesteDirectory $game -RepositoryRoot $workspace -RuntimeIdentifier $rid | Out-Null }
            catch { $rejected = $true }
            if (-not $rejected -or (Test-Path -LiteralPath (Join-Path $workspace 'artifacts/runtime'))) { throw 'Invalid native closure was copied before complete validation.' }
            continue
        }
        & $restoreScript -CelesteDirectory $game -RepositoryRoot $workspace -RuntimeIdentifier $rid | Out-Null
        $runtime = Join-Path $workspace "artifacts/runtime/$rid"
        if ($rid -eq 'linux-x64') {
            foreach ($target in @((Join-Path $runtime 'libfmod_SDL.so'), (Join-Path $workspace 'Unity/Assets/Plugins/FMOD/linux-x64/libfmod_SDL.so'))) {
                if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "Linux FMOD SDL output shim missing: $target" }
            }
            if (Test-Path -LiteralPath (Join-Path $runtime 'libfmod_SDL.so.10')) { throw 'The SDL shim must retain its actual unversioned filename.' }
            foreach ($stem in @('libfmod', 'libfmodstudio')) {
                $expectedSource = Join-Path $nativeInput ($stem + $(if ($case -eq 'canonical') { '.so' } elseif ($case -eq 'sdk-patch-filename') { '.so.10.14' } else { '.so.10' }))
                $sourceBytes = [IO.File]::ReadAllBytes($expectedSource)
                $expectedBytes = [byte[]]$sourceBytes.Clone()
                $expectedBytes[68] = 6
                $expected = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($expectedBytes))
                $manifestRecord = Get-Content -LiteralPath (Join-Path $runtime 'manifest.json') -Raw | ConvertFrom-Json | Where-Object File -eq "$stem.so"
                if ($manifestRecord.SourceSHA256 -cne $sourceHashes[$expectedSource] -or $manifestRecord.SHA256 -cne $expected) { throw 'Source and normalized deployment hashes were not recorded independently.' }
                $deployedBytes = [IO.File]::ReadAllBytes((Join-Path $runtime "$stem.so"))
                $difference = @(for ($byteIndex = 0; $byteIndex -lt $sourceBytes.Length; $byteIndex++) { if ($sourceBytes[$byteIndex] -ne $deployedBytes[$byteIndex]) { $byteIndex } })
                if ($case -eq 'non-executable-stack') {
                    if ($difference.Count -ne 0 -or $manifestRecord.Normalization.Changed) { throw 'A non-executable stack library was changed.' }
                }
                elseif ($difference.Count -ne 1 -or $difference[0] -ne 68 -or ($sourceBytes[68] -bxor $deployedBytes[68]) -ne 1) { throw 'Normalization changed bytes outside the GNU stack execute flag.' }
                foreach ($target in @((Join-Path $runtime "$stem.so"), (Join-Path $runtime "$stem.so.10"), (Join-Path $workspace "Unity/Assets/Plugins/FMOD/linux-x64/$stem.so"), (Join-Path $workspace "Unity/Assets/Plugins/FMOD/linux-x64/$stem.so.10"))) {
                    if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -cne $expected) { throw "Canonical or transitive SONAME copy differs: $target" }
                }
                if ($IsLinux) {
                    foreach ($aliasDirectory in @($runtime, (Join-Path $workspace 'Unity/Assets/Plugins/FMOD/linux-x64'))) {
                        $alias = Get-Item -LiteralPath (Join-Path $aliasDirectory "$stem.so.10")
                        $primary = Get-Item -LiteralPath (Join-Path $aliasDirectory "$stem.so")
                        if ($alias.LinkTarget -cne "$stem.so" -or $primary.LinkTarget -or $alias.ResolveLinkTarget($true).FullName -cne $primary.FullName) { throw 'FMOD aliases do not identify one physical staged library.' }
                    }
                }
            }
        }
        elseif (-not (Test-Path -LiteralPath (Join-Path $runtime 'libMoltenVK.dylib') -PathType Leaf)) { throw 'macOS orig/osx native restoration failed.' }
        $publishedHashes = @{}
        foreach ($published in Get-ChildItem -LiteralPath $runtime -File) { $publishedHashes[$published.Name] = (Get-FileHash -LiteralPath $published.FullName -Algorithm SHA256).Hash }
        & $restoreScript -CelesteDirectory $game -RepositoryRoot $workspace -RuntimeIdentifier $rid | Out-Null
        foreach ($published in Get-ChildItem -LiteralPath $runtime -File) {
            if ((Get-FileHash -LiteralPath $published.FullName -Algorithm SHA256).Hash -cne $publishedHashes[$published.Name]) { throw 'Repeated native restoration was not byte-idempotent.' }
        }
        foreach ($original in Get-ChildItem -LiteralPath $game -File -Recurse) {
            if ((Get-FileHash -LiteralPath $original.FullName -Algorithm SHA256).Hash -cne $sourceHashes[$original.FullName]) { throw 'A supplied native SDK input was modified.' }
        }
    }
    $workspace = Join-Path $directory 'adapter-publication'
    $RuntimeIdentifier = 'linux-x64'
    $Configuration = 'Release'
    $build = Join-Path $workspace 'build'
    $plugins = Join-Path $workspace 'Unity/Assets/Runtime/Plugins/linux-x64'
    $hostRuntime = Join-Path $workspace 'artifacts/runtime/linux-x64'
    foreach ($folder in @((Join-Path $build $Configuration), $plugins, $hostRuntime)) { [IO.Directory]::CreateDirectory($folder) | Out-Null }
    $adapters = @('GfxPluginCelesteGraphicsUnityVulkan')
    $filename = Get-CelesteNativeFileName $adapters[0] $RuntimeIdentifier
    $adapterSource = Join-Path $build "$Configuration/$filename"
    Write-NativeHeaderFixture $adapterSource $RuntimeIdentifier
    $buildScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'Build-Native.ps1'
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($buildScript, [ref]$tokens, [ref]$parseErrors)
    $loop = $ast.Find({ param($node) $node -is [Management.Automation.Language.ForEachStatementAst] -and $node.Condition.Extent.Text -eq '$adapters' }, $true)
    if ($parseErrors.Count -or -not $loop) { throw 'Native adapter publication loop is missing or invalid.' }
    & ([scriptblock]::Create($loop.Extent.Text))
    $expected = (Get-FileHash -LiteralPath $adapterSource -Algorithm SHA256).Hash
    foreach ($target in @((Join-Path $plugins $filename), (Join-Path $hostRuntime $filename))) {
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -cne $expected) { throw 'Native adapter publication did not preserve its source bytes.' }
    }
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'NativeLibraryAliases.ps1')
    $aliasDirectory = Join-Path $directory 'alias-normalization'
    [IO.Directory]::CreateDirectory($aliasDirectory) | Out-Null
    $aliasRid = if ($IsMacOS) { 'osx-x64' } else { 'linux-x64' }
    $primaryName = if ($IsMacOS) { 'libFAudio.0.dylib' } else { 'libFAudio.so.0' }
    $aliasName = if ($IsMacOS) { 'libFAudio.dylib' } else { 'libFAudio.so' }
    $primaryPath = Join-Path $aliasDirectory $primaryName
    $aliasPath = Join-Path $aliasDirectory $aliasName
    [IO.File]::WriteAllText($primaryPath, 'primary')
    [IO.File]::WriteAllText($aliasPath, 'different')
    $rejected = $false
    try { Set-CelesteNativeLibraryAliases -Directory $aliasDirectory -RuntimeIdentifier $aliasRid }
    catch { $rejected = $true }
    if ($IsLinux -or $IsMacOS) {
        if (-not $rejected -or [IO.File]::ReadAllText($aliasPath) -cne 'different') { throw 'Conflicting native alias contents were merged or mutated.' }
        [IO.File]::WriteAllText($aliasPath, 'primary')
        Set-CelesteNativeLibraryAliases -Directory $aliasDirectory -RuntimeIdentifier $aliasRid
        $alias = Get-Item -LiteralPath $aliasPath
        if ($alias.LinkTarget -cne $primaryName -or $alias.ResolveLinkTarget($true).FullName -cne $primaryPath) { throw 'Relative native alias normalization failed.' }
        $linkCreated = $alias.CreationTimeUtc
        Set-CelesteNativeLibraryAliases -Directory $aliasDirectory -RuntimeIdentifier $aliasRid
        if ((Get-Item -LiteralPath $aliasPath).CreationTimeUtc -ne $linkCreated) { throw 'Idempotent normalization replaced an already-correct alias.' }
    }
    elseif ($rejected -or (Get-Item -LiteralPath $aliasPath).LinkTarget) { throw 'Windows cross-staging unexpectedly normalized POSIX aliases.' }
    Write-Output 'Passed fourteen native dependency fixtures: staged GNU stack normalization, immutable SDK inputs, relative canonical/SONAME aliases, conflicting-alias rejection, repeat idempotence, complete preflight rejection, Linux SDL shim, macOS discovery and adapter publication.'
}
finally {
    $resolved = [IO.Path]::GetFullPath($directory)
    $boundary = $parent.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($boundary, [StringComparison]::Ordinal) -or [IO.Path]::GetFileName($resolved) -notmatch '^celeste-native-restore-[a-f0-9]{32}$') { throw 'Temporary restore fixture escaped its boundary.' }
    [IO.Directory]::Delete($resolved, $true)
}
