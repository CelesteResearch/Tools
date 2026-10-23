[English](README.md) | [简体中文](README.zh-CN.md)

# Tools

Resource restoration, native builds and host/module preparation. Place this repository at workspace Tools/. Runtime content lives in Content/; native dependencies live in `artifacts/runtime/<rid>/`.

## Requirements

- Windows x64, Linux x64, or macOS x64; PowerShell 7 and a .NET 10 SDK matching each repository's global.json. On Apple Silicon, run x64 PowerShell, .NET, Unity/Godot and dependencies through Rosetta. FMOD 1.10.14 does not provide a native Apple Silicon runtime.
- CMake 3.24+ and a C/C++ compiler: Visual Studio 2022 desktop tools and Windows SDK on Windows, GCC/Clang on Linux, or Xcode Command Line Tools on macOS. Add CMake to PATH or pass -CMakeExecutable.
- Unity: Shared, Unity and Tools repositories, Unity 6000.6.0f1 and licensed Odin Inspector.
- Godot: Shared, Godot and Tools repositories, Godot 4.5.1 Mono/.NET; matching export templates for export.
- A Celeste installation with **Everest 6580 stable** ([release](https://github.com/EverestAPI/Everest/releases/tag/stable-1.6580.0),
  [installer archive](https://github.com/EverestAPI/Everest/releases/download/stable-1.6580.0/main.zip)),
  the matching original assembly under orig/, and FNA.dll. The rebuild reference
  versions are FNA 24.1, MonoMod.Utils 25.0.9 and Mono.Cecil 0.11.6. Compile-time
  resources must match AssetRestore/resource-map.json.
- Desktop audio banks built from the official Celeste FMOD project. Supply FMOD 1.10.14 x64 for the target OS, SDL2, FNA3D, FAudio, libtheorafile and Lua 5.4 from your installation or their respective distributions. Use -NativeDependencyDirectory when they are not located in the game installation. Libraries must match the selected OS and architecture; Windows DLLs cannot be reused on Linux/macOS.
- On Linux/macOS, supply -FrameworkTimeResourceDirectory containing the original mscorlib.resources and optional `mscorlib.<culture>.resources` files, or -FrameworkDirectory pointing to a legally obtained .NET Framework installation. Windows uses its installed .NET Framework by default.
- For TAS, the Mods/TAS repository and the installed CelesteTAS ZIP.

## Prepare a host

Run from the parent workspace; replace paths with your installations.

```powershell
pwsh ./Tools/Prepare.ps1 `
  -CelesteDirectory 'D:/Games/Celeste' `
  -AudioBankDirectory 'D:/Audio/Celeste/Desktop' `
  -UnityEditorDirectory 'D:/Tools/Unity/6000.6.0f1/Editor' `
  -OdinDirectory 'D:/LicensedPlugins/Sirenix' `
  -Targets Unity
```

UnityEditorDirectory contains Data/PluginAPI on Windows/Linux, or is the macOS Unity.app bundle containing Contents/PluginAPI. OdinDirectory contains Assemblies/Sirenix.OdinInspector.Editor.dll; Odin can also be installed directly at Unity/Assets/Plugins/Sirenix.

For Godot:

```powershell
pwsh ./Tools/Prepare.ps1 `
  -CelesteDirectory 'D:/Games/Celeste' `
  -AudioBankDirectory 'D:/Audio/Celeste/Desktop' `
  -Targets Godot
```

For Linux or macOS, run the same entry point with the matching native libraries and time resources:

```sh
pwsh ./Tools/Prepare.ps1 -CelesteDirectory /path/to/Celeste -AudioBankDirectory /path/to/Desktop -NativeDependencyDirectory /path/to/native-libraries -FrameworkTimeResourceDirectory /path/to/time-resources -Targets Godot
```

The runtime identifier defaults to the current process architecture and OS. Use `-RuntimeIdentifier win-x64`, `linux-x64` or `osx-x64` to select it explicitly. Native builds run on their target OS. On macOS, `CelesteDirectory` may also point to the game's app bundle. Original managed resource identities remain pinned by AssetRestore/resource-map.json.

Windows provides D3D11, Vulkan and D3D12. Linux uses Vulkan; macOS uses Vulkan through a separately supplied compatible MoltenVK loader. Unity's macOS presenter also uses the shared renderer. Keep MoltenVK and its required dependencies in the deployed native-library directory, following their distribution terms.

| Option                          | Behavior                                                                                                                                          |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| -Targets All                    | Prepare both hosts.                                                                                                                               |
| -Targets Managed -CompileOnly   | Restore compile-time inputs and build managed projects; skip runtime installation and native preparation.                                         |
| -IncludeHelpers                 | Build the 42 source Helper ports, rebuild the 9 recipe Mods and package their original content; requires all 51 Helper repositories and Mods/TAS. |
| -RuntimeIdentifier              | Select win-x64, linux-x64 or osx-x64; all native libraries and host processes must match.                                                         |
| -NativeDependencyDirectory      | Directory containing native libraries for the selected OS and architecture.                                                                       |
| -FrameworkTimeResourceDirectory | Directory containing original .NET Framework time-format resources.                                                                               |
| -WithoutTas                     | Skip standalone TAS preparation/installation; retain existing installations. Helper dependencies may still compile TAS projects.                  |

## Helpers and Strawberry Jam

Check out every component from the workspace directory:

```sh
git submodule update --init --recursive
```

Keep Strawberry Jam and its dependency ZIPs together in the original game's
`Mods/` directory. The nine local rebuild repositories specify each supported
archive version, download link and filename:

- [BounceHelper][bouncehelper-readme]: 1.14.1, `BounceHelper.zip`.
- [CollabLobbyUI][collablobbyui-readme]: 1.0.9, `CollabLobbyUI.zip`.
- [ContortHelper][contorthelper-readme]: 1.5.5, `ContortHelper.zip`.
- [DJMapHelper][djmaphelper-readme]: 1.13.4, `DJMapHelper.zip`.
- [DisposableTheo][disposabletheo-readme]: 1.0.6, `DisposableTheo.zip`.
- [LunaticHelper][lunatichelper-readme]: 1.1.1, `LunaticHelper.zip`.
- [MoreDasheline][moredasheline-readme]: 1.7.1, `MoreDasheline.zip`.
- [PrismaticHelper][prismatichelper-readme]: 1.12.0, `PrismaticHelper.zip`.
- [SpirialisHelper][spirialishelper-readme]: 1.0.8, `SpirialisHelper.zip`.

Add `-IncludeHelpers` to the host preparation command above. Preparation builds
`Helpers.slnx` first, reconstructs and compiles the nine recipe Mods from their
locked original inputs, then packages their assemblies and original content in
`Content/Celeste/Mods/`. The original installation and ZIPs remain unchanged.
Generated source and intermediate files stay under ignored `artifacts/`.

A checked-out Mods/TAS is prepared automatically. Individual Mods can be built through their own projects with their actual dependencies.

After preparation, follow the selected host's README to run it. Standalone resource restoration and additional input options are documented in [AssetRestore](AssetRestore/README.md).

## Install TAS separately

After restoring resources:

```powershell
dotnet build ./Mods/TAS/Celeste.Mods.Tas.csproj -c Release
pwsh ./Tools/Install-Tas.ps1
```

The installer places the module, manifest, Lua script, Dialog/Graphics content and required runtime dependencies at Content/Celeste/Mods/TAS/.

## Platform checks

Run `pwsh ./Tools/Tests/Test-Platform.ps1` to check runtime identifier, library filename and PE/ELF/Mach-O architecture handling without game assets. The Shared repository includes an asset-free native build workflow for Windows, Linux and macOS. Full game preparation still requires the resources listed above.

## Licenses

Tool contributions use AGPL-3.0-only; see [NOTICE.md](NOTICE.md). Supplied resources and dependencies retain their respective licenses.

[bouncehelper-readme]: https://github.com/CelesteResearch/BounceHelper/blob/main/README.md
[collablobbyui-readme]: https://github.com/CelesteResearch/CollabLobbyUI/blob/main/README.md
[contorthelper-readme]: https://github.com/CelesteResearch/ContortHelper/blob/main/README.md
[djmaphelper-readme]: https://github.com/CelesteResearch/DJMapHelper/blob/main/README.md
[disposabletheo-readme]: https://github.com/CelesteResearch/DisposableTheo/blob/main/README.md
[lunatichelper-readme]: https://github.com/CelesteResearch/LunaticHelper/blob/main/README.md
[moredasheline-readme]: https://github.com/CelesteResearch/MoreDasheline/blob/main/README.md
[prismatichelper-readme]: https://github.com/CelesteResearch/PrismaticHelper/blob/main/README.md
[spirialishelper-readme]: https://github.com/CelesteResearch/SpirialisHelper/blob/main/README.md
