# Android Shell 与打包代码审查

审查日期：2026-10-16。文件：`AssetInstaller.java`、`LauncherActivity.java`、`GameActivity.java`、`scripts/android/package_game.py`、`build_apk.py`。此为代码审查，未代替安装/升级/生命周期实测；父任务在同时修改代码，下述发现以所列触发条件为准。

## 需要修正或验证

1. **虚拟键覆盖不全（核心功能）**：审查时 `GameActivity.createControls` 只有 C/X/Z/A/Q/W。固定 native `src/input/keybindings.cpp:81` 至 `:85` 明确 D→Input::Z/SPECIAL、A→Input::X/JUMPUP、S→Input::Y/JUMPDOWN；游戏仓库 `UI_PokemonStorage.rb:1344`、`:1351`、`:1358` 依赖后三者切箱与箱名。需补 S、D，修正 A 的 Menu 标签，或提供同等快捷键菜单。
2. **安装并发（恢复/数据保护）**：`LauncherActivity` 的 working 是 Activity 实例字段，原始 new Thread 不会随 Activity 销毁停止。Back 关闭安装界面后立即重新启动可能并发写同一目标和 `.installing` 文件；实例布尔无法互斥。需文件锁或进程级串行安装，失败/关闭后不能产生第二个活动安装器。
3. **断点恢复空间预算**：`AssetInstaller.install` 对部分完成树仍要求 `usable >= manifest.bytes + 128 MiB`，随后重写每个文件。用户原本空间够首装，完成大半后中断，重试却可能要求额外完整内容空间。建议核验/复用已完成项并计算剩余量；至少在首版说明需要的额外空间，实测低空间中断恢复。
4. **原生库失败生命周期**：审查时 GameActivity 在 `mBrokenLibraries` 为真后仍在 `onResume` / `onPause` 调 native thread 方法，可能让原本可显示的加载失败再变成 UnsatisfiedLinkError。需在相同失败状态下防护 native 调用，并做故意缺库路径测试。
5. **完整性标记后缺失文件**：存在 `.complete` 时直接返回，不检查必须文件和 Graphics 链接是否仍有效。当前缓存/素材手工失效后不会触发重建。可以先只核验关键启动文件与链接，提供明确修复入口；不要每次首屏全量 hash 近 1 GiB。
6. **Ruby IO 路径分隔符**：游戏 `pbResolveBitmap` 的 `safeExists?` 直接走 `FileTest.exist?`，标题与电影实际传反斜杠；native PHYSFS/pathCache 只会帮助 native 读取，不会自动纠正 Ruby IO。应以 Android 首次画面核实，并在平台路径接口接入归一/大小写解析。黑画面中不停更新 FPS 不能记为游戏标题启动通过。
7. **打包中断与 --skip-payload**：payload ZIP 已先写 `.pending` 再 replace，方向正确；manifest/config 分别写出。打包中断后配对文件可能不一致，`--skip-payload` 仅检查存在。installer hash 会拒绝错误包，但这类包可在构建阶段成功签名。建议 skip 时验证 ZIP/manifest 配对，或用完整 staging 目录原子提交。

## 已核对的正面证据

- 固定源码 `src/main.cpp:284` 用当前 Activity 的静态 `GAME_PATH` JNI 字段切 CWD；GameActivity 保留该字段，默认 SDL getLibraries 包含 SDL2、SDL2_image、SDL2_ttf、SDL2_sound、openal、ruby、mkxp-z，且最后一个是入口库。没有额外 getArguments 需求。
- Android minSdk=30，当前 WindowInsets.Type / getInsets 在该下限内；原生 ARM64/4KB/16KB 限制仍需按 runtime 报告约束兼容范围。
- 安装代码将 saves 放 app files/saves，未写入内容版本目录；普通内容升级不直接覆盖槽文件。
- 最新审查快照已把 Graphics 改为 `writable/Graphics-{contentId}`，并在新内容 hash 检查完成后迁移下载和用户改图；这解决了最初共享 Graphics 在失败升级时改动旧版本树的问题。
- Zip 文件写出采用 allowlist、固定文件顺序/时间戳、每项 SHA256 与大小；解包有 canonical path 边界检查、`.installing`、fsync、完成标记。
- 打包包含 Fonts、Audio、Data、Graphics，排除根目录玩家存档、temp、BAT/EXE。游戏 loader 下非 Ruby 文件明确拒绝，避免误把文档执行为代码。
- Manifest 暂无 INTERNET 权限，Ruby 平台层也默认禁 Android HTTP；这是已知 native TLS 缺少证书验证期间的双重约束。
- 签名为 temp 下本地测试 keystore，未将发布私钥放仓库；build record 明确 gameplay validation pending。

## 补充兼容修复

游戏没有 File.exists?/Dir.exists? 兼容实现，选定 native Ruby 3.4.10 已删除这两个旧方法。Android preload 已补缺省 alias，Windows 不动，并用 Windows portable Ruby 3.2.9 模拟缺失和 runtime 自带实现两种情况。包含后续路径接入的 38 个平台契约断言通过，详见 `platform-test-strategy.md`。

## 运行时探针生命周期只读复查

父任务发出 Home/重新进入应用操作后，本审查仅读取 emulator-5554 日志，未操作 UI、结束或安装应用。logcat 原值显示同一游戏进程 PID 8395：`08:48:22.245 nativePause`、`:22.254 onPause`、`:23.396 onStop`、`:23.805 onStart`、`:23.806 onResume`、`:24.557 nativeResume`；之后仍持续输出约 39–41 FPS，短时范围可到 37–42。

源码中 GameActivity 与 SDLActivity 都会请求 pause/resume；SDLActivity.handleNativeState 对相同目标/当前状态立即返回，因此重复请求本身不重复执行 native 转换。当前快照也已防护 broken libraries 状态。日志没有支持持续生命周期死锁；父任务所述 input CLI 约 30 秒等待发生在 onPause 之前，更符合模拟器/系统输入服务负载或调度延迟，但单次日志尚不足定位其具体原因。本结果仅覆盖原生运行时探针的这一次前后台切换，不扩展为完整 KIF 生命周期验收。
