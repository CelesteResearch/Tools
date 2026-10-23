function Restore-ModDecompiler {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)]$ToolLock
    )
    if ($ToolLock.toolVersion -cne '10.1.0.8386') { throw 'Unsupported decompiler version.' }
    $installRoot = Get-RecipePath $RepositoryRoot 'artifacts/tools/ilspy/10.1.0.8386'
    $toolRoot = Get-RecipePath $installRoot '.store/ilspycmd/10.1.0.8386/ilspycmd/10.1.0.8386/tools/net10.0/any'
    if (-not [IO.Directory]::Exists($toolRoot)) {
        & dotnet tool install ilspycmd --version '10.1.0.8386' --tool-path $installRoot --add-source 'https://api.nuget.org/v3/index.json' --no-cache --verbosity minimal | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Unable to restore the pinned ILSpy tool.' }
    }
    if ($ToolLock.Contains('frameworkReferences')) {
        $frameworkRoot = Get-RecipePath $toolRoot 'framework'
        $missing = @($ToolLock.frameworkReferences | Where-Object { -not [IO.File]::Exists((Get-RecipePath $toolRoot $_.path)) })
        if ($missing.Count) {
            $project = Join-Path $PSScriptRoot 'ModDecompilerReferences/Celeste.Tools.ModDecompilerReferences.csproj'
            & dotnet restore $project --locked-mode --nologo -v minimal | Out-Host
            if ($LASTEXITCODE -ne 0) { throw 'Unable to restore the pinned framework reference package.' }
            & dotnet msbuild $project -target:CopyPinnedReferences "-property:ReferenceOutputDirectory=$frameworkRoot" -verbosity:quiet -nologo -nodeReuse:false | Out-Host
            if ($LASTEXITCODE -ne 0) { throw 'Unable to prepare the pinned framework references.' }
        }
    }
    foreach ($file in $ToolLock.toolFiles) {
        [void](Read-RecipeFile $toolRoot $file.path $file.sha256 -HashOnly)
    }
    $toolRoot
}
