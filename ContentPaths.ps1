function Get-CelesteContentPaths {
    param([Parameter(Mandatory)][string]$WorkspaceRoot)

    $resourceDirectory = [IO.Path]::GetFullPath((Join-Path $WorkspaceRoot 'Content'))
    [pscustomobject]@{
        ResourceDirectory = $resourceDirectory
        Game = Join-Path $resourceDirectory 'Celeste'
        Everest = Join-Path $resourceDirectory 'Everest'
        FrameworkTimeResources = Join-Path $resourceDirectory 'CelesteFrameworkTimeResources'
    }
}
