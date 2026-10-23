[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$UnityEditorDirectory,
    [string]$CMakeExecutable,
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Release',
    [switch]$WithoutUnity,
    [string]$RuntimeIdentifier
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Platform.ps1')
$RuntimeIdentifier = Get-CelesteRuntimeIdentifier $RuntimeIdentifier
if ($RuntimeIdentifier -notin @('win-x64', 'linux-x64', 'osx-x64')) { throw 'Desktop preparation requires x64 native dependencies; use x64 hosts under Rosetta on Apple Silicon.' }
$root = [IO.Path]::GetFullPath($RepositoryRoot)
if (-not $CMakeExecutable) {
    $installed = Get-Command cmake -ErrorAction SilentlyContinue
    if ($installed) { $CMakeExecutable = $installed.Source }
    elseif ($IsWindows) {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
        if (Test-Path -LiteralPath $vswhere) {
            $CMakeExecutable = & $vswhere -latest -products '*' -find 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe' | Select-Object -First 1
        }
    }
}
if (-not $CMakeExecutable -or -not (Test-Path -LiteralPath $CMakeExecutable)) { throw 'Install CMake 3.24+ and a platform C++ compiler, or pass -CMakeExecutable.' }
$shared = Join-Path $root 'Shared'
$unity = Join-Path $root 'Unity'
$runtime = Join-Path $shared "artifacts/runtime/$RuntimeIdentifier"
$savedPath = $env:PATH
try {
    $env:PATH = (Split-Path $CMakeExecutable -Parent) + [IO.Path]::PathSeparator + $env:PATH
    & (Join-Path $shared 'tools/Build-Graphics.ps1') -Configuration $Configuration -RuntimeIdentifier $RuntimeIdentifier -CMakeExecutable $CMakeExecutable
    if ($LASTEXITCODE -ne 0) { throw 'Shared native build failed.' }
    if ($WithoutUnity) { return }
    if (-not $UnityEditorDirectory) { throw 'Pass -UnityEditorDirectory pointing to the installed Unity Editor or its app bundle.' }
    $pluginApi = @('Data/PluginAPI', 'Contents/PluginAPI', 'PluginAPI') | ForEach-Object { Join-Path $UnityEditorDirectory $_ } | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'IUnityInterface.h') } | Select-Object -First 1
    if (-not $pluginApi) { throw 'UnityEditorDirectory must contain the native PluginAPI headers.' }
    $build = Join-Path $root "artifacts/native/Unity/$RuntimeIdentifier"
    $configure = @('-S', (Join-Path $unity 'Native/Graphics'), '-B', $build, "-DUNITY_PLUGIN_API=$pluginApi", "-DCELESTE_SHARED=$shared", "-DCELESTE_NATIVE_RUNTIME=$runtime", "-DCMAKE_BUILD_TYPE=$Configuration")
    if ($IsWindows) { $configure += @('-A', 'x64') }
    if ($IsMacOS) { $configure += '-DCMAKE_OSX_ARCHITECTURES=x86_64' }
    & $CMakeExecutable @configure
    if ($LASTEXITCODE -ne 0) { throw 'Unity native configuration failed.' }
    & $CMakeExecutable --build $build --config $Configuration --parallel 4
    if ($LASTEXITCODE -ne 0) { throw 'Unity native build failed.' }
    $plugins = Get-CelesteUnityPluginDirectory $unity $RuntimeIdentifier
    [IO.Directory]::CreateDirectory($plugins) | Out-Null
    $libraries = @('CelesteGraphicsVulkan', 'CelesteGraphicsEffects')
    if ($IsWindows) { $libraries += @('CelesteGraphicsD3D11', 'CelesteGraphicsDirect3D12') }
    foreach ($name in $libraries) { Copy-Item -LiteralPath (Join-Path $runtime (Get-CelesteNativeFileName $name $RuntimeIdentifier)) -Destination $plugins -Force }
    $adapters = if ($IsWindows) { @('CelesteGraphicsUnityD3D11', 'GfxPluginCelesteGraphicsUnityVulkan', 'GfxPluginCelesteGraphicsUnityDirect3D12') } elseif ($IsMacOS) { @('GfxPluginCelesteGraphicsUnityMetal', 'CelesteUnityPlatform') } else { @('GfxPluginCelesteGraphicsUnityVulkan', 'CelesteUnityPlatform') }
    $hostRuntime = Join-Path $root "artifacts/runtime/$RuntimeIdentifier"
    [IO.Directory]::CreateDirectory($hostRuntime) | Out-Null
    foreach ($name in $adapters) {
        $filename = Get-CelesteNativeFileName $name $RuntimeIdentifier
        $source = @((Join-Path $build "$Configuration/$filename"), (Join-Path $build $filename)) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if (-not $source) { throw "Built Unity native adapter missing: $filename" }
        if ($RuntimeIdentifier -notin @(Get-CelesteNativeArchitectures $source)) { throw "Built Unity native adapter architecture differs: $filename" }
        $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        foreach ($destinationDirectory in @($plugins, $hostRuntime)) {
            $destination = Join-Path $destinationDirectory $filename
            Copy-Item -LiteralPath $source -Destination $destination -Force
            if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -cne $sourceHash) { throw "Published Unity native adapter differs: $destination" }
        }
    }
}
finally { $env:PATH = $savedPath }
