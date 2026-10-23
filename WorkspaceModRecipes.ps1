function New-WorkspaceModRecipeLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$ToolLockPath,
        [string[]]$Modules
    )
    Set-StrictMode -Version Latest
    $workspaceInputs = [Collections.Generic.List[object]]::new()
    function Read-WorkspaceDefinition([string]$Path) {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $workspaceInputs.Add([pscustomobject]@{ Path = [IO.Path]::GetFullPath($Path); Sha256 = Get-RecipeSha $bytes; Bytes = $null })
        [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    }
    $toolLock = $null
    $registered = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $gitmodules = Read-WorkspaceDefinition (Join-Path $RepositoryRoot '.gitmodules')
    foreach ($line in $gitmodules.Split("`n")) {
        if ($line -match '^\s*path\s*=\s*(Mods/[A-Za-z][A-Za-z0-9._-]*)\s*$') { [void]$registered.Add($Matches[1].Substring(5)) }
    }
    $sourcePorts = (Read-WorkspaceDefinition (Join-Path $RepositoryRoot 'Tools/mod-packages.json')) | ConvertFrom-Json -AsHashtable
    foreach ($port in $sourcePorts.modules) {
        $parts = $port.project.Replace('\', '/').Split('/')
        if ($parts.Count -ge 3 -and $parts[0] -ceq 'Mods') { [void]$registered.Remove($parts[1]) }
    }
    # TAS retains its existing separately optional Prepare path.
    [void]$registered.Remove('TAS')
    $requested = if ($Modules) { @($Modules) } else { @($registered | Sort-Object) }
    foreach ($id in $requested) { if (-not $registered.Contains($id)) { throw "No local-rebuild repository is registered for '$id'." } }
    $selected = [ordered]@{}
    $issues = [Collections.Generic.List[string]]::new()
    $visiting = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    function Resolve-WorkspaceRecipe([string]$Id) {
        if ($selected.Contains($Id)) { return }
        if (-not $registered.Contains($Id)) { throw "A rebuilt dependency is not registered: $Id." }
        if (-not $visiting.Add($Id)) { throw "Rebuild dependency cycle: $Id." }
        $directory = Get-RecipePath $RepositoryRoot "Mods/$Id"
        $manifestPath = Get-RecipePath $directory 'mod-rebuild.json'
        if (-not [IO.File]::Exists($manifestPath)) {
            $issues.Add("$Id (missing mod-rebuild.json)")
            [void]$visiting.Remove($Id)
            return
        }
        $manifest = (Read-WorkspaceDefinition $manifestPath) | ConvertFrom-Json -AsHashtable
        if ($manifest.schemaVersion -ne 1 -or $manifest.id -cne $Id -or $manifest.mode -cne 'local-rebuild') { throw "Invalid per-Mod rebuild manifest: $Id." }
        $recipePath = Get-RecipePath $directory $manifest.recipe
        if (-not [IO.File]::Exists($recipePath)) {
            $issues.Add("$Id (missing $($manifest.recipe))")
            [void]$visiting.Remove($Id)
            return
        }
        if ($manifest.assemblyName -cnotmatch '^[A-Za-z_][A-Za-z0-9_.-]*$') { throw "Invalid rebuilt assembly name: $Id." }
        $recipeBytes = [IO.File]::ReadAllBytes($recipePath)
        $recipe = [Text.UTF8Encoding]::new($false, $true).GetString($recipeBytes) | ConvertFrom-Json -AsHashtable
        $projects = @($recipe.outputs | Where-Object { $_.path.EndsWith('.csproj', [StringComparison]::Ordinal) })
        if ($projects.Count -ne 1) { throw "Expected one locked project: $Id." }
        foreach ($dependency in $manifest.dependencies) { Resolve-WorkspaceRecipe $dependency }
        $selected[$Id] = @{
            id = $manifest.id
            version = $manifest.version
            completeModule = $true
            archive = @{ path = $manifest.archive.path; sha256 = $manifest.archive.sha256 }
            dependencies = @($manifest.dependencies)
            files = @()
            project = $projects[0].path
            assembly = "bin/Release/netstandard2.1/$($manifest.assemblyName).dll"
            converter = @{
                recipe = [IO.Path]::GetRelativePath($RepositoryRoot, $recipePath).Replace('\', '/')
                sha256 = Get-RecipeSha $recipeBytes
                inputs = @($recipe.inputs | ForEach-Object { @{ path = $_.path; sha256 = $_.sha256 } })
                outputs = @($recipe.outputs | ForEach-Object { @{ path = $_.path; sha256 = $_.sha256 } })
            }

        }
        if ($manifest.ContainsKey('archiveSources')) {
            if ($manifest.ContainsKey('decompileTypes')) { throw "A Mod manifest declares two original source strategies: $Id." }
            $selected[$Id].archiveSources = @($manifest.archiveSources)
            $selected[$Id].originalAssembly = $manifest.originalAssembly
        }
        else {
            $selected[$Id].decompile = @{
                assemblyEntry = $manifest.originalAssembly.entry
                assemblySha256 = $manifest.originalAssembly.sha256
                types = @($manifest.decompileTypes)
            }
        }
        [void]$visiting.Remove($Id)
    }
    foreach ($id in $requested) { Resolve-WorkspaceRecipe $id }
    if ($issues.Count) { throw ('Complete local rebuild recipes are required: ' + ($issues -join '; ') + '.') }
    if ($selected.Count -eq 0) { return $null }
    foreach ($inputFile in $workspaceInputs) { if ((Get-RecipeFileSha $inputFile.Path) -cne $inputFile.Sha256) { throw 'Workspace definitions changed during preflight.' } }
    $lock = @{ schemaVersion = 1; modules = @($selected.Values) }
    if (@($selected.Values | Where-Object { $_.ContainsKey('decompile') }).Count -gt 0) {
        $toolLock = (Read-WorkspaceDefinition $ToolLockPath) | ConvertFrom-Json -AsHashtable
        $lock.decompiler = $toolLock
    }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($lock | ConvertTo-Json -Depth 40) + "`n")
    $hash = Get-RecipeSha $bytes
    $lockPath = Get-RecipePath $RepositoryRoot "artifacts/local-mod-locks/$hash.json"
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($lockPath)) | Out-Null
    [IO.File]::WriteAllBytes($lockPath, $bytes)
    [pscustomobject]@{ Path = $lockPath; Sha256 = $hash; ToolLock = $toolLock; Inputs = $workspaceInputs.ToArray() }
}

function Get-WorkspaceModRecipePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$CelesteDirectory,
        [Parameter(Mandatory)][string]$ToolsDirectory,
        [string[]]$Modules
    )
    Set-StrictMode -Version Latest
    $definition = New-WorkspaceModRecipeLock -RepositoryRoot $RepositoryRoot -ToolLockPath (Join-Path $ToolsDirectory 'ilspy-tool-lock.json') -Modules $Modules
    if (-not $definition) { return $null }
    $decompiler = $null
    if ($definition.ToolLock) { $decompiler = Restore-ModDecompiler -RepositoryRoot $RepositoryRoot -ToolLock $definition.ToolLock }
    $project = Join-Path $ToolsDirectory 'ModSourceConverter/Celeste.Tools.ModSourceConverter.csproj'
    $output = Get-RecipePath $RepositoryRoot 'artifacts/tools/ModSourceConverter'
    Push-Location $RepositoryRoot
    try {
        & dotnet build $project -c Release --nologo -v minimal -m:1 -nodeReuse:false '-p:UseSharedCompilation=false' '-p:RestoreLockedMode=true' --output $output --artifacts-path (Join-Path $RepositoryRoot 'artifacts/tool-build') | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Unable to build the pinned Mod converter.' }
    }
    finally { Pop-Location }
    $plan = Get-LockedModRecipePlan -RecipeLock $definition.Path -ExpectedLockSha256 $definition.Sha256 -SourceModsDirectory (Join-Path $CelesteDirectory 'Mods') -SourceCodeDirectory $CelesteDirectory -RecipeDirectory $RepositoryRoot -RepositoryRoot $RepositoryRoot -ConverterAssembly (Join-Path $output 'Celeste.Tools.ModSourceConverter.dll') -DecompilerDirectory $decompiler -ReferenceDirectory $CelesteDirectory
    $plan.Inputs = @($plan.Inputs) + @($definition.Inputs)
    $plan
}
