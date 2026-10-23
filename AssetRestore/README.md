[English](README.md) | [简体中文](README.zh-CN.md)

# Restore resources

Run from the workspace with PowerShell 7 and .NET SDK 10:

```powershell
pwsh ./Tools/AssetRestore/Restore-Assets.ps1 -CelesteDirectory 'D:/Games/Celeste' -RepositoryRoot .
```

The installation must contain Everest, the matching original assembly under orig/, and FNA.dll (or orig/FNA.dll). Compile-time embedded resources, including seven framework effect bytecodes, must match resource-map.json.

To restore runtime content:

```powershell
pwsh ./Tools/AssetRestore/Restore-Assets.ps1 -CelesteDirectory 'D:/Games/Celeste' -RepositoryRoot . -IncludeRuntimeContent -AudioBankDirectory 'D:/Audio/Celeste/Desktop'
```

Supply Desktop banks built from the official Celeste FMOD project with compatible FMOD Studio 1.10 tools. Runtime content is placed under workspace Content/.

Options:

- -TasArchive selects the CelesteTAS ZIP; otherwise the tool looks for Mods/CelesteTAS*.zip in the installation. It supplies TAS dialogue, graphics and HUD font assets.
- -FrameworkDirectory selects .NET Framework 4.x. Windows defaults to %WINDIR%/Microsoft.NET/Framework64/v4.0.30319.
- -FrameworkTimeResourceDirectory supplies extracted mscorlib*.resources instead.

Install the optional TAS module using Tools/Install-Tas.ps1 after building Mods/TAS. The workspace preparation entry point also handles native dependencies and host assemblies; see the [Tools README](../README.md).
