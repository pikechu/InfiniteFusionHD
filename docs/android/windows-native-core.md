# Windows portable mkxp core build

2026-10-20：**固定提交的完整mkxp ARM64核心已在Windows portable工具链编译、链接并通过打包门禁；独立完整源码运行时探针已在API30模拟器通过基础运行验证**。当前游戏APK尚未切换该运行时。
当前游戏APK仍使用固定上游预编译core；新构建的Ruby及完整核心分别进入独立probe验证。源码编译、诊断APK构建和设备运行分别记录。
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
& $python -B android/tests/windows_native_core_guards_test.py
& $python -B scripts/android/windows_native_core.py --stage prepare
```

首次源码准备：在`temp/windows-native/sources/mkxp-z`新建专用Git checkout，从锁文件URL只fetch固定commit，然后detached checkout。脚本拒绝不同HEAD、脏checkout和只有export文件的源码目录；不替用户重置已有目录。

`--stage prepare`只写本任务temp下的machine files和缺失依赖清单；最终缺失清单已为空。libiconv也已从固定GNU1.18归档重新解压源码，API30单任务configure/make/install实际通过，耗时约260秒（不含解压）。`libiconv.so`977,872字节，SHA256 `66d500c2a58be062e9fa01c43569b6c41c2f7ecb64a075b6823ec2efaf397f01`；`libcharset.so`5,584字节，SHA256 `f16c393787e5571339f8971164302c6275bed4dd8c3fd44bb66681980e3d567e`。两者ARM64、正确SONAME、全部16KiB LOAD、无RPATH/RUNPATH，必要iconv导出通过。证据`temp/windows-native/libiconv-build-result.json`及其中run目录。

```powershell
./scripts/android/windows-native-iconv.ps1 -Fetch -Jobs 1
# 已有官方归档时用 -SourceArchive <路径>，仍核对固定SHA并重新解压到新run。
```

依赖全部具备后：

```powershell
& $python -B scripts/android/windows_native_core.py --stage configure
& $python -B scripts/android/windows_native_core.py --stage build --jobs 1
```

输出留在`temp/windows-native-core`，不会写入APK staging或操作AVD。实际运行前先检查Ruby安装产物与完整无RUNPATH验证记录匹配。机器配置用内容哈希绑定构建目录，工具链变化需选新的`--output`，不会静默重用其他交叉工具链。构建结束仍需审查完整依赖闭包、符号、NDK C++库和整体16KiB兼容，再在独立probe中运行；单个库的16KiB LOAD不能证明整个APK兼容16KiB设备。

## 完整核心实际产物

全部112个Ninja步骤实际完成，固定上游源码保持干净。首次链接库含Meson自动加入的Windows prefix RUNPATH，严格门禁如实失败；原库、日志及ELF保留在`history/first-link-with-host-runpath`。这是主机安装路径清理问题，未把不合格库发给游戏。

随后用固定Meson1.9.1的官方`depfixer.fix_elf`安装清理逻辑处理**独立副本**。输入和输出长度相同，除`.dynamic`的768字节范围外，全部字节逐项相同；代码、只读数据、字符串表、ELF头/段布局均未改动。最终重新检查SONAME、全部16KiB LOAD、依赖、无RPATH/RUNPATH，及前后源码/依赖hash一致。

- 原始链接库：`build/libmkxp-z.so`，SHA256 `c9009caa91c994c45f6972e63bcaedfa565a3612343ff122748d53abdc274482`。
- 可用于独立probe的库：`packaged/libmkxp-z.so`，3,463,072字节，SHA256 `fab5f32f2642d7ac58d552a3e3dd1f75fabc16e22f274e7ff70364d2a3d3a96c`。
- `build-result.json`记录`coreBuilt=true`、`targetExecuted=false`，以及完整依赖SHA、pkg-config SHA和打包变换证据。`fullRuntimeBuilt=false`保留到完整闭包与Android运行验收，不能把此字段改成游戏已通过。

以上构建记录保持构建时的静态状态，不回填覆盖。随后独立探针APK `Native-Full-Runtime-Probe-arm64-test.apk`（26,642,468字节，SHA256 `4185c549967455c5fdd1a531ecbbdfc7b71bcaed73dd80224d06b7329acf4952`）已在emulator-5554实际通过：OpenSSL/socket/zlib/Digest功能、原始Marshal严格二进制往返、公共Marshal的既定UTF8转换且所有字节/类型不变、源构建JNI桥、字体1859像素及120帧（3.09922秒）。完整源码core未应用旧二进制翻译补丁。证据`temp/evidence/native-full-device-contracts`含结果、日志、截图、PSS及主游戏QA存档前后全哈希一致证明。这是基础诊断，不是KIF玩法验收；NDKr25c的标准`libc++_shared.so`仍为4KiB页例外，整体16KiB未通过，也没有真机结论。

清理函数源自已校验wheel，SHA256 `4b48f133b31c6119ad9a26d1c735ae23b279b5d2024d0f23795d4e5d93b37513`。Windows盘符会被RPATH的冒号分隔，因此按实际旧搜索条目的分段精确移除，并要求最终无任意RPATH/RUNPATH标签，而非仅删一个字符串。

实现依据：[Meson交叉编译](https://mesonbuild.com/Cross-compilation.html)、[Meson machine files](https://mesonbuild.com/Machine-files.html)，以及固定运行时源码的`meson.build`、`src/meson.build`、`shader/meson.build`、`assets/meson.build`。

## 主机隔离复查

独立代码审查发现并修正四项：清理`CPATH`等宿主搜索变量；重配时`--reconfigure --clearcache`避免旧pkg-config缓存；核对实际执行的251项Meson文件以及pkgconf EXE/DLL，而非只检查归档和版本串；拒绝输出子路径及已有build树中的junction/symlink。10项实际主机回归已全部通过、无跳过，包括版本不变的工具篡改、额外Python模块、真实环境恢复、3种Windows Junction及固定Meson依赖元数据更新实验。自动生成的字节码目录由bootstrap移至独立temp隔离位置保留，不会忽略额外源代码。所有Meson子进程使用`-B`及`PYTHONDONTWRITEBYTECODE=1`，防止重复产生缓存。该回归不运行任何Android代码。
