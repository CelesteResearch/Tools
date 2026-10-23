[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Platform.ps1')

$parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$directory = Join-Path $parent ('celeste-platform-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($directory) | Out-Null
$cases = 0
try {
    foreach ($rid in @('win-x64', 'linux-x64', 'osx-x64', 'linux-arm64', 'osx-arm64')) {
        if ((Get-CelesteRuntimeIdentifier $rid) -cne $rid) { throw "Runtime identifier changed: $rid" }
        $expected = if ($rid.StartsWith('win-')) { 'Celeste.dll' } elseif ($rid.StartsWith('linux-')) { 'libCeleste.so' } else { 'libCeleste.dylib' }
        if ((Get-CelesteNativeFileName 'Celeste' $rid) -cne $expected) { throw "Wrong native filename: $rid" }
        $cases++
    }
    foreach ($rid in @('win-x64', 'win-arm64')) {
        $bytes = [byte[]]::new(128)
        $bytes[0] = 0x4d
        $bytes[1] = 0x5a
        $bytes[60] = 64
        $bytes[64] = 0x50
        $bytes[65] = 0x45
        if ($rid.EndsWith('-x64')) { $bytes[68] = 0x64; $bytes[69] = 0x86 }
        else { $bytes[68] = 0x64; $bytes[69] = 0xaa }
        $file = Join-Path $directory $rid
        [IO.File]::WriteAllBytes($file, $bytes)
        if ((Get-CelesteNativeArchitectures $file) -cne $rid) { throw "Wrong PE architecture: $rid" }
        $cases++
    }
    foreach ($rid in @('linux-x64', 'linux-arm64', 'osx-x64', 'osx-arm64')) {
        $bytes = [byte[]]::new(64)
        if ($rid.StartsWith('linux-')) {
            [Array]::Copy([byte[]]@(0x7f, 0x45, 0x4c, 0x46, 2, 1), $bytes, 6)
            $bytes[18] = if ($rid.EndsWith('-x64')) { 62 } else { 183 }
        }
        else {
            [Array]::Copy([byte[]]@(0xcf, 0xfa, 0xed, 0xfe), $bytes, 4)
            $bytes[4] = if ($rid.EndsWith('-x64')) { 7 } else { 12 }
            $bytes[7] = 1
        }
        $file = Join-Path $directory $rid
        [IO.File]::WriteAllBytes($file, $bytes)
        if ((Get-CelesteNativeArchitectures $file) -cne $rid) { throw "Wrong native header architecture: $rid" }
        $cases++
    }
    $fat = [byte[]]::new(64)
    [Array]::Copy([byte[]]@(0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 2), $fat, 8)
    [Array]::Copy([byte[]]@(1, 0, 0, 7), 0, $fat, 8, 4)
    [Array]::Copy([byte[]]@(1, 0, 0, 12), 0, $fat, 28, 4)
    $file = Join-Path $directory 'universal.dylib'
    [IO.File]::WriteAllBytes($file, $fat)
    if ((@(Get-CelesteNativeArchitectures $file) -join ',') -cne 'osx-x64,osx-arm64') { throw 'Universal Mach-O slices were not preserved.' }
    $cases++
    [IO.File]::WriteAllBytes($file, [byte[]]@(1, 2, 3))
    $rejected = $false
    try { Get-CelesteNativeArchitectures $file | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Truncated native header was accepted.' }
    $cases++
    Write-Output "Passed $cases platform identifier, native filename and PE/ELF/Mach-O boundary cases."
}
finally {
    $resolved = [IO.Path]::GetFullPath($directory)
    $boundary = $parent.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($boundary, [StringComparison]::Ordinal) -or [IO.Path]::GetFileName($resolved) -notmatch '^celeste-platform-[a-f0-9]{32}$') { throw 'Temporary test directory escaped its boundary.' }
    [IO.Directory]::Delete($resolved, $true)
}
