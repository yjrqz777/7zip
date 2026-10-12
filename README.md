# 7-Zip on GitHub

7-Zip website: [7-zip.org](https://7-zip.org)

## 编译与安装

面向 Windows 11 x64。需要 Visual Studio 2022 或 Build Tools 2022，选择“使用 C++ 的桌面开发”，安装 MSVC（Microsoft Visual C++，微软 C++ 编译工具）v143 x64/x86 和 Windows 11 SDK（Software Development Kit，软件开发工具包）。使用 Windows PowerShell 5.1 或 PowerShell 7。

在项目根目录执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build-win11.ps1
```

脚本默认打包根目录 `Lang` 中的语言文件（需包含 `zh-cn.txt`）。中间文件集中保存到 `build\win11-x64`，安装包为 `dist\win11-x64\7z-26.04-x64-setup.exe`。以管理员身份运行安装包，选择原安装目录即可覆盖安装；文件被占用时可能需要重启完成替换。

## 变更点 （增加智能解压）

- 右键菜单新增“智能解压至此”，默认启用，可在 7-Zip 菜单设置中关闭。
- 单个文件或单个顶层目录直接解压到当前位置；其他结构创建以压缩包名称命名的目录，重名时追加 ` (2)`、` (3)` 等后缀。多选压缩包时分别判断。
- 新增命令行解压模式 `-spos`，并提供包含语言文件、右键扩展和卸载器的安装包构建脚本。
