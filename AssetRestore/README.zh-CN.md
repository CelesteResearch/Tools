[English](README.md) | [简体中文](README.zh-CN.md)

# 恢复资源

从工作区使用 PowerShell 7 和 .NET SDK 10 执行：

```powershell
pwsh ./Tools/AssetRestore/Restore-Assets.ps1 -CelesteDirectory 'D:/Games/Celeste' -RepositoryRoot .
```

安装目录需包含 Everest、orig/ 中匹配的原版程序集及 FNA.dll（或 orig/FNA.dll）。编译所需嵌入资源，包括七个框架效果字节码，应匹配 resource-map.json。

恢复运行内容：

```powershell
pwsh ./Tools/AssetRestore/Restore-Assets.ps1 -CelesteDirectory 'D:/Games/Celeste' -RepositoryRoot . -IncludeRuntimeContent -AudioBankDirectory 'D:/Audio/Celeste/Desktop'
```

提供使用兼容 FMOD Studio 1.10 工具从官方 Celeste FMOD 工程构建的 Desktop banks。运行内容恢复到工作区 Content/。

选项：

- -TasArchive 指定 CelesteTAS ZIP；默认查找安装目录的 Mods/CelesteTAS*.zip，用于提供 TAS 对话、图像及 HUD 字体。
- -FrameworkDirectory 指定 .NET Framework 4.x。Windows 默认位置为 %WINDIR%/Microsoft.NET/Framework64/v4.0.30319。
- -FrameworkTimeResourceDirectory 改为提供已提取的 mscorlib*.resources。

构建 Mods/TAS 后使用 Tools/Install-Tas.ps1 安装可选 TAS 模块。工作区准备入口同时处理原生依赖和宿主程序集，见 [Tools README](../README.zh-CN.md)。
