[English](README.md) | [简体中文](README.zh-CN.md)

# Tools

资源恢复、原生构建及宿主和模块准备工具。仓库位于工作区 Tools/，运行内容位于 Content/，原生依赖位于 `artifacts/runtime/<rid>/`。

## 环境要求

- Windows x64、Linux x64 或 macOS x64，PowerShell 7，以及符合各仓库 global.json 的 .NET 10 SDK。Apple Silicon 使用 Rosetta 运行 x64 的 PowerShell、.NET、Unity／Godot 和原生依赖；FMOD 1.10.14 没有原生 Apple Silicon 运行库。
- CMake 3.24+ 与 C/C++ 编译器：Windows 使用 Visual Studio 2022 桌面开发工具和 Windows SDK，Linux 使用 GCC／Clang，macOS 使用 Xcode Command Line Tools。CMake 加入 PATH，或通过 -CMakeExecutable 指定。
- Unity：Shared、Unity、Tools 仓库，Unity 6000.6.0f1 和已授权 Odin Inspector。
- Godot：Shared、Godot、Tools 仓库，Godot 4.5.1 Mono/.NET；导出时需要对应导出模板。
- 安装 **Everest 6580 稳定版**的 Celeste（[发行版](https://github.com/EverestAPI/Everest/releases/tag/stable-1.6580.0)、
  [安装包](https://github.com/EverestAPI/Everest/releases/download/stable-1.6580.0/main.zip)），
  以及 orig/ 中匹配的原版程序集和 FNA.dll。
  重建所需引用版本为 FNA 24.1、MonoMod.Utils 25.0.9、Mono.Cecil 0.11.6。
  编译资源应匹配 AssetRestore/resource-map.json。
- 从官方 Celeste FMOD 工程构建的 Desktop 音频 banks。提供目标系统的 FMOD 1.10.14 x64、SDL2、FNA3D、FAudio、libtheorafile 和 Lua 5.4，可从自己的安装或相应项目的发行版获取。不在游戏安装目录中时，通过 -NativeDependencyDirectory 指定。所有原生库必须匹配系统和架构，Windows DLL 不能用于 Linux／macOS。
- Linux／macOS 还需通过 -FrameworkTimeResourceDirectory 提供原始 mscorlib.resources 和可选 `mscorlib.<culture>.resources`，或通过 -FrameworkDirectory 指定合法获取的 .NET Framework 安装目录。Windows 默认使用已安装的 .NET Framework。
- TAS 另需 Mods/TAS 仓库及已安装的 CelesteTAS ZIP。

## 准备宿主

从父级工作区执行，路径替换为自己的安装位置。

```powershell
pwsh ./Tools/Prepare.ps1 `
  -CelesteDirectory 'D:/Games/Celeste' `
  -AudioBankDirectory 'D:/Audio/Celeste/Desktop' `
  -UnityEditorDirectory 'D:/Tools/Unity/6000.6.0f1/Editor' `
  -OdinDirectory 'D:/LicensedPlugins/Sirenix' `
  -Targets Unity
```

Windows／Linux 的 UnityEditorDirectory 包含 Data/PluginAPI；macOS 则指定包含 Contents/PluginAPI 的 Unity.app。OdinDirectory 包含 Assemblies/Sirenix.OdinInspector.Editor.dll；也可直接安装到 Unity/Assets/Plugins/Sirenix。

Godot：

```powershell
pwsh ./Tools/Prepare.ps1 `
  -CelesteDirectory 'D:/Games/Celeste' `
  -AudioBankDirectory 'D:/Audio/Celeste/Desktop' `
  -Targets Godot
```

Linux／macOS 使用相同入口，并提供对应原生库和时间资源：

```sh
pwsh ./Tools/Prepare.ps1 -CelesteDirectory /path/to/Celeste -AudioBankDirectory /path/to/Desktop -NativeDependencyDirectory /path/to/native-libraries -FrameworkTimeResourceDirectory /path/to/time-resources -Targets Godot
```

运行时标识默认取当前进程的系统和架构，也可显式指定 `-RuntimeIdentifier win-x64`、`linux-x64` 或 `osx-x64`。原生构建在目标系统上执行。macOS 的 CelesteDirectory 也可指定游戏 app 包；原始托管资源的身份仍由 AssetRestore/resource-map.json 校验。

Windows 提供 D3D11、Vulkan 和 D3D12；Linux 使用 Vulkan；macOS 通过另行提供的兼容 MoltenVK 加载器使用 Vulkan。Unity 的 macOS 呈现同样消费共享渲染器。按其分发条款，将 MoltenVK 及所需依赖放入部署的原生库目录。

| 选项                            | 行为                                                                                                |
| ------------------------------- | --------------------------------------------------------------------------------------------------- |
| -Targets All                    | 准备两个宿主。                                                                                      |
| -Targets Managed -CompileOnly   | 恢复编译输入并构建托管项目，跳过运行安装与原生准备。                                                |
| -IncludeHelpers                 | 构建 42 个源码 Helper，重建 9 个 recipe Mod 并打包原始内容；需要全部 51 个 Helper 仓库及 Mods/TAS。 |
| -RuntimeIdentifier              | 选择 win-x64、linux-x64 或 osx-x64；原生库和宿主进程必须匹配。                                      |
| -NativeDependencyDirectory      | 指定所选系统和架构的原生库目录。                                                                    |
| -FrameworkTimeResourceDirectory | 指定包含原始 .NET Framework 时间格式资源的目录。                                                    |
| -WithoutTas                     | 跳过独立 TAS 准备和安装，保留已有安装；Helper 的项目依赖仍可能编译 TAS。                            |

## Helper 与草莓酱

在工作区目录检出全部组件：

```sh
git submodule update --init --recursive
```

将草莓酱及其依赖的原始 ZIP 一起放在原游戏的 `Mods/` 目录。
9 个本地重建仓库分别列出支持的压缩包版本、下载链接及文件名：

- [BounceHelper][bouncehelper-readme-zh-cn]：1.14.1，`BounceHelper.zip`。
- [CollabLobbyUI][collablobbyui-readme-zh-cn]：1.0.9，`CollabLobbyUI.zip`。
- [ContortHelper][contorthelper-readme-zh-cn]：1.5.5，`ContortHelper.zip`。
- [DJMapHelper][djmaphelper-readme-zh-cn]：1.13.4，`DJMapHelper.zip`。
- [DisposableTheo][disposabletheo-readme-zh-cn]：1.0.6，`DisposableTheo.zip`。
- [LunaticHelper][lunatichelper-readme-zh-cn]：1.1.1，`LunaticHelper.zip`。
- [MoreDasheline][moredasheline-readme-zh-cn]：1.7.1，`MoreDasheline.zip`。
- [PrismaticHelper][prismatichelper-readme-zh-cn]：1.12.0，`PrismaticHelper.zip`。
- [SpirialisHelper][spirialishelper-readme-zh-cn]：1.0.8，`SpirialisHelper.zip`。

在上面的宿主准备命令中添加 `-IncludeHelpers`。准备流程先构建 `Helpers.slnx`，
再从校验过的原始输入重建并编译 9 个 Mod，最后将程序集与原始内容打包到
`Content/Celeste/Mods/`。原安装目录及 ZIP 保持不变，生成源码和中间文件位于已忽略的
`artifacts/` 目录。

已检出的 Mods/TAS 会自动准备。单个 Mod 可在检出实际依赖后构建其项目。

准备后按所选宿主 README 启动。独立资源恢复及其他输入选项见 [AssetRestore](AssetRestore/README.zh-CN.md)。

## 单独安装 TAS

资源恢复后执行：

```powershell
dotnet build ./Mods/TAS/Celeste.Mods.Tas.csproj -c Release
pwsh ./Tools/Install-Tas.ps1
```

安装器将模块、manifest、Lua 脚本、Dialog/Graphics 内容及运行依赖放到 Content/Celeste/Mods/TAS/。

## 平台检查

运行 `pwsh ./Tools/Tests/Test-Platform.ps1`，无需游戏素材即可检查运行时标识、库文件名和 PE／ELF／Mach-O 架构处理。Shared 仓库包含 Windows、Linux 和 macOS 的无素材原生构建工作流；完整游戏准备仍需上述资源。

## 许可证

工具贡献采用 AGPL-3.0-only，见 [NOTICE.md](NOTICE.md)。外部资源和依赖保留各自许可。

[bouncehelper-readme-zh-cn]: https://github.com/CelesteResearch/BounceHelper/blob/main/README.zh-CN.md
[collablobbyui-readme-zh-cn]: https://github.com/CelesteResearch/CollabLobbyUI/blob/main/README.zh-CN.md
[contorthelper-readme-zh-cn]: https://github.com/CelesteResearch/ContortHelper/blob/main/README.zh-CN.md
[djmaphelper-readme-zh-cn]: https://github.com/CelesteResearch/DJMapHelper/blob/main/README.zh-CN.md
[disposabletheo-readme-zh-cn]: https://github.com/CelesteResearch/DisposableTheo/blob/main/README.zh-CN.md
[lunatichelper-readme-zh-cn]: https://github.com/CelesteResearch/LunaticHelper/blob/main/README.zh-CN.md
[moredasheline-readme-zh-cn]: https://github.com/CelesteResearch/MoreDasheline/blob/main/README.zh-CN.md
[prismatichelper-readme-zh-cn]: https://github.com/CelesteResearch/PrismaticHelper/blob/main/README.zh-CN.md
[spirialishelper-readme-zh-cn]: https://github.com/CelesteResearch/SpirialisHelper/blob/main/README.zh-CN.md
