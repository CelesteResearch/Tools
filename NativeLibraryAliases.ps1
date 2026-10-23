function Set-CelesteNativeLibraryAliases {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$RuntimeIdentifier
    )
    if (-not (($IsLinux -and $RuntimeIdentifier.StartsWith('linux-')) -or ($IsMacOS -and $RuntimeIdentifier.StartsWith('osx-')))) { return }
    $groups = if ($IsLinux) {
        @{
            'libSDL2-2.0.so.0' = @('libSDL2.so', 'libSDL2-2.0.so')
            'libFAudio.so.0' = @('libFAudio.so')
            'libFNA3D.so.0' = @('libFNA3D.so')
            'libfmod.so' = @('libfmod.so.10', 'libfmod.so.10.14')
            'libfmodstudio.so' = @('libfmodstudio.so.10', 'libfmodstudio.so.10.14')
        }
    }
    else {
        @{
            'libSDL2-2.0.0.dylib' = @('libSDL2.dylib')
            'libFAudio.0.dylib' = @('libFAudio.dylib')
            'libFNA3D.0.dylib' = @('libFNA3D.dylib')
        }
    }
    # Validate every alias before replacing any file. Distinct libraries must never be merged.
    $pending = foreach ($primaryName in $groups.Keys) {
        $paths = @(@($primaryName) + $groups[$primaryName] | ForEach-Object { Join-Path $Directory $_ } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
        if ($paths.Count -lt 2) { continue }
        $hashes = @($paths | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash } | Select-Object -Unique)
        if ($hashes.Count -ne 1) { throw "Native aliases have different contents: $($paths -join ', ')" }
        [pscustomobject]@{ Primary = Join-Path $Directory $primaryName; Paths = $paths; SHA256 = $hashes[0] }
    }
    foreach ($group in $pending) {
        $primary = Get-Item -LiteralPath $group.Primary -Force -ErrorAction SilentlyContinue
        if (-not $primary -or $primary.LinkTarget) {
            $bytes = [IO.File]::ReadAllBytes($group.Paths[0])
            if ($primary) { Remove-Item -LiteralPath $group.Primary -Force }
            [IO.File]::WriteAllBytes($group.Primary, $bytes)
        }
        $primaryName = [IO.Path]::GetFileName($group.Primary)
        foreach ($path in $group.Paths) {
            if ($path -ceq $group.Primary) { continue }
            $alias = Get-Item -LiteralPath $path -Force
            if ($alias.LinkTarget -cne $primaryName) {
                Remove-Item -LiteralPath $path -Force
                New-Item -ItemType SymbolicLink -Path $path -Target $primaryName | Out-Null
            }
            if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $group.SHA256) { throw "Native alias differs after publication: $path" }
        }
    }
}
