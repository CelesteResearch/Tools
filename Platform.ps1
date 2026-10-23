function Get-CelesteRuntimeIdentifier {
    param([string]$RuntimeIdentifier)
    if ($RuntimeIdentifier) {
        if ($RuntimeIdentifier -notin @('win-x64', 'linux-x64', 'linux-arm64', 'osx-x64', 'osx-arm64')) { throw "Unsupported runtime identifier: $RuntimeIdentifier" }
        return $RuntimeIdentifier
    }
    $platform = if ($IsWindows) { 'win' } elseif ($IsLinux) { 'linux' } elseif ($IsMacOS) { 'osx' } else { throw 'Unsupported desktop operating system.' }
    $architecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
    if ($architecture -notin @('x64', 'arm64') -or ($platform -eq 'win' -and $architecture -ne 'x64')) { throw "Unsupported process architecture: $architecture" }
    return "$platform-$architecture"
}

function Get-CelesteNativeFileName {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$RuntimeIdentifier)
    if ($RuntimeIdentifier.StartsWith('win-')) { return "$Name.dll" }
    if ($RuntimeIdentifier.StartsWith('linux-')) { return "lib$Name.so" }
    return "lib$Name.dylib"
}

function Get-CelesteUnityPluginDirectory {
    param([Parameter(Mandatory)][string]$UnityRoot, [Parameter(Mandatory)][string]$RuntimeIdentifier, [switch]$Fmod)
    $parent = if ($Fmod) { 'Assets/Plugins/FMOD' } else { 'Assets/Runtime/Plugins' }
    $directory = if ($RuntimeIdentifier -eq 'win-x64') { 'x86_64' } else { $RuntimeIdentifier }
    return Join-Path $UnityRoot "$parent/$directory"
}

function Get-CelesteNativeArchitectures {
    param([Parameter(Mandatory)][string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($stream.Length -lt 32) { throw "Native library header is truncated: $Path" }
        $magic = $reader.ReadUInt32()
        if (($magic -band 0xffff) -eq 0x5a4d) {
            $stream.Position = 0x3c
            $peOffset = $reader.ReadUInt32()
            if ($peOffset -gt $stream.Length - 6) { throw "Invalid PE header: $Path" }
            $stream.Position = $peOffset
            if ($reader.ReadUInt32() -ne 0x00004550) { throw "Invalid PE signature: $Path" }
            switch ($reader.ReadUInt16()) { 0x8664 { 'win-x64' } 0xaa64 { 'win-arm64' } default { throw "Unsupported PE architecture: $Path" } }
            return
        }
        if ($magic -eq 0x464c457f) {
            $stream.Position = 4
            if ($reader.ReadByte() -ne 2 -or $reader.ReadByte() -ne 1) { throw "Expected a little-endian 64-bit ELF library: $Path" }
            $stream.Position = 18
            switch ($reader.ReadUInt16()) { 62 { 'linux-x64' } 183 { 'linux-arm64' } default { throw "Unsupported ELF architecture: $Path" } }
            return
        }
        if ($magic -eq 4277009103) {
            switch ($reader.ReadUInt32()) { 0x01000007 { 'osx-x64' } 0x0100000c { 'osx-arm64' } default { throw "Unsupported Mach-O architecture: $Path" } }
            return
        }
        if ($magic -in @(3199925962, 3216703178)) {
            function Read-BigEndianUInt32 {
                $bytes = $reader.ReadBytes(4)
                if ($bytes.Length -ne 4) { throw "Truncated universal Mach-O header: $Path" }
                [Array]::Reverse($bytes)
                return [BitConverter]::ToUInt32($bytes)
            }
            $count = Read-BigEndianUInt32
            if ($count -gt 64) { throw "Invalid universal Mach-O architecture count: $Path" }
            for ($index = 0; $index -lt $count; $index++) {
                $cpu = Read-BigEndianUInt32
                switch ($cpu) { 0x01000007 { 'osx-x64' } 0x0100000c { 'osx-arm64' } }
                $stream.Position += $(if ($magic -eq 3216703178) { 28 } else { 16 })
            }
            return
        }
        throw "Unrecognized native library format: $Path"
    }
    finally { $reader.Dispose() }
}

function Get-CelesteInstallationDirectory {
    param([Parameter(Mandatory)][string]$Directory)
    $root = (Resolve-Path -LiteralPath $Directory).Path
    foreach ($relative in @('', 'Contents/MacOS', 'Contents/Resources', 'Contents/Resources/Celeste')) {
        $candidate = if ($relative) { Join-Path $root $relative } else { $root }
        if ((Test-Path -LiteralPath (Join-Path $candidate 'Celeste.dll') -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $candidate 'Celeste.exe') -PathType Leaf)) { return $candidate }
    }
    throw 'CelesteDirectory must contain Celeste.dll/Celeste.exe, or be the macOS game app bundle.'
}
