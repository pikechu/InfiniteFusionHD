# Windows portable mkxp core build

2026-10-20：**构建准备和最小工具链编译通过，完整mkxp core尚未编译/运行**。
当前游戏APK仍使用固定上游预编译core；新构建的Ruby先通过独立probe验证，不能与完整运行时源码重建混淆。
依赖构建与Ruby历史见[Windows原生构建](windows-native-build.md)。

## 已实际验证

- 官方Meson 1.9.1纯Python wheel、MSYS2 UCRT pkgconf包免安装解压到`temp/core-tools`；下载SHA固定在`windows-native-core.lock.json`，不使用全局pip/pacman。
- pkgconf官方包为`1~3.0.9-1`，实际`--version`输出`3.0.8`。这与[上游3.0.9标签的meson.build](https://raw.githubusercontent.com/pkgconf/pkgconf/pkgconf-3.0.9/meson.build)中的项目版本相符；锁文件分别记录包版本和输出版本，未放松归档SHA检查。
- 专用Git checkout固定为`68653811c3c396f2d4c12225c52c407746285a3d`，位于`temp/windows-native/sources/mkxp-z`。没有使用外层KIF Git版本冒充运行时提交。
- 原runtime使用Meson，不是CMake。Windows cross-file直接调用NDK `clang.exe`/`clang++.exe --target=aarch64-linux-android30`，只查询Android prefix的pkg-config条目，禁止Meson下载fallback子项目，也不执行ARM64探测程序。
- 上游`xxd-include.sh`经Meson native-file替换为纯Python主机生成器。对9个字节边界样本、全部shader和3个内置资源共45个实际输入，与固定上游脚本及已安装Git的sh/xxd输出逐字节相同。没有修改目标C++或shader内容。
- 最小真实Meson/Ninja构建已执行：41,976字节`libkif_meson_toolchain_probe.so`，SHA256 `951cf32dec86baf679e5a139ff664d37b90a21fd56779b9a8c7d2238b510a92c`。编译期断言ARM64/API30，实际执行Python资源生成、C++编译和链接；ELF全部LOAD为16KiB、引用NDK `libc++_shared.so`，没有RPATH/RUNPATH。该库没有在Android加载，且不是RGSS运行时。

证据：`temp/core-tools/environment.json`、`codegen-validation.json`、`temp/windows-native-core/toolchain-probe-{configure,compile}.log`、`toolchain-probe-elf.txt`、`toolchain-probe-result.json`。

## 复现

在隔离worktree根目录，使用已有portable Python 3.11+：

```powershell
$python = '<portable Python完整路径>'
./scripts/android/windows-native-meson.ps1 -PythonPath $python -Fetch
& $python -B android/tests/windows_codegen_test.py --git-bin '<现有Git目录>/usr/bin'
& $python -B android/tests/windows_meson_probe.py
& $python -B scripts/android/windows_native_core.py --stage prepare
```

首次源码准备：在`temp/windows-native/sources/mkxp-z`新建专用Git checkout，从锁文件URL只fetch固定commit，然后detached checkout。脚本拒绝不同HEAD、脏checkout和只有export文件的源码目录；不替用户重置已有目录。

`--stage prepare`只写本任务temp下的machine files和缺失依赖清单；它已成功执行。当前缺少openal/theora/SDL2_ttf/pixman/uchardet/SDL2_image pkg-config条目及相应库、SDL2_sound和iconv，媒体依赖正在逐项构建。这是准备结果，**不是完整core构建失败或通过**。

依赖全部具备后：

```powershell
& $python -B scripts/android/windows_native_core.py --stage configure
& $python -B scripts/android/windows_native_core.py --stage build --jobs 1
```

输出留在`temp/windows-native-core`，不会写入APK staging或操作AVD。实际运行前先检查Ruby安装产物与完整无RUNPATH验证记录匹配。机器配置用内容哈希绑定构建目录，工具链变化需选新的`--output`，不会静默重用其他交叉工具链。构建结束仍需审查完整依赖闭包、符号、NDK C++库和整体16KiB兼容，再在独立probe中运行；单个库的16KiB LOAD不能证明整个APK兼容16KiB设备。

实现依据：[Meson交叉编译](https://mesonbuild.com/Cross-compilation.html)、[Meson machine files](https://mesonbuild.com/Machine-files.html)，以及固定运行时源码的`meson.build`、`src/meson.build`、`shader/meson.build`、`assets/meson.build`。
