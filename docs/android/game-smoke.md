# 真实运行时游戏数据集成探针

测试文件：`android/ruby/android-game-smoke.rb`。Android 设备/模拟器执行状态：**pending**；只有设备日志中的 `KIF_GAME_SMOKE_PASS` 才能确认本次实际运行通过。本地 Ruby 语法检查和 mock 平台测试不算设备结果。

## 启动方式与数据保护

将此文件打包到游戏根目录，显式将该诊断安装副本 mkxp.json 的 `customScript` 设为 `android-game-smoke.rb`。正常游戏配置不引用它，没有默认启动行为改变。原生 customScript 分支绕过正常 preloadScript，因此探针自行加载游戏根 `kif_android_preload.rb`。

探针按实际 loader 的“每层文件排序先执行，然后目录排序递归”加载全部 Data/Scripts，仅跳过包含无限主循环的 `999_Main`。不加载玩家 Mods，不调用 `Game.set_up_system`，不发现、读取或覆盖任何正式存档槽。

随后运行安全的新进程启动步骤：消息表、已编译 PluginScripts、禁编译 Compiler.main、Game.initialize、全新 SaveData boot/new-game values。测试只向 `ENV['KIF_SAVE_DIR']/android-integration-probe.rxdata` 写文件；关闭探针进程内闪光缓存写入。日志到 stdout/logcat，不写游戏日志文件。重复执行可以读取上次的这个专用探针文件并输出 `KIF_GAME_SMOKE_PROBE_RELOAD_PASS`，用于与父任务的 force-stop/重启记录组合验证进程重启。

## 真实覆盖

- 完整游戏脚本装载、后加载 Bitmap 扩展、真实编译物种/招式/系统数据及新进程对象初始化。
- 真正 Pokemon 构造、stats/learnset；真正 FusedSpecies 的组合、反向 ID 和拆分 helper；真实 PokemonFusionScene 的 IV averaging helper。
- 普通 Bulbasaur 和真实闪光 renderer/native Bitmap 输出；拒绝 1x1/32x32 缺图占位，要求透明外有实际像素且闪光有像素变化。
- 后加载 `Bitmap#hue_customcolor` 的确定性像素/alpha 断言。
- **真实 pbUnfuse**：以真实 FusedSpecies Pokemon 及已知元数据作输入，只临时自动确认 UI 并记录消息，实际生产函数创建两个 Pokemon、保留经验/闪光、写入真实 PokemonStorage。确认方法在 ensure 中恢复，未替换任何融合/拆分计算。
- 真实仓库 Store/Move、跨箱内容与源位置变化；真实 Player/PokemonSystem/PokemonStorage 的原生 Marshal 专用文件往返。

## 明确不覆盖

`pbFuse` 与 `reverseFusion` 把模型变更和动画/能力/招式选择 UI 混在一起。当前探针只覆盖组合/反向数据模型及融合 IV helper，没有执行这两个动画入口，不得记录为融合动画或反向融合完整流程通过。

探针也没有覆盖地图移动、战斗、捕捉、进化、正式 SaveData 槽格式、多存档菜单、Windows 存档导入、生命周期或触控。通过页明确显示 `Gameplay and UI acceptance pending`，并输出 `KIF_GAME_SMOKE_PENDING` 项目。

## 记录要求

保留设备/API/runtime/APK与payload hash、从 BEGIN 到 PASS/FAIL 的完整日志、PASS界面截图、各阶段耗时。首轮不存在专用文件应输出 FIRST_RUN；真正 force-stop 后重新启动必须看到 PROBE_RELOAD_PASS，二者不得混淆。失败日志包含 stage 和最后一个完整脚本路径，便于定位无界面加载异常。

## 首次 Android 运行发现（尚未整轮通过）

设备日志 2026-10-16 显示：真实脚本装载通过（18.3897s），fresh globals/compiled data 通过（93.9773s），Pokemon/Fusion model 16 个断言通过。随后 Ruby File.file? 能看到真实精灵文件，但 normal/shiny 实际输出 32x32，触发拒绝占位断言。源 BaseSprites/1.png、1l.png 都是 288x288；Bulbasaur 的 size_category 固定 AVERAGE、sprite_scale=1，recognizeDims 只将 96 放大到 288，因此这次不是随机尺寸假失败。

进一步只读核对：设备 Graphics 是指向 writable/Graphics-id 的符号链接；native pathCache 枚举仅递归 PHYSFS_stat 的 DIRECTORY 类型。官方 [PHYSFS_stat 契约](https://wiki.icculus.org/PhysicsFS3/PHYSFS_stat) 明确 stat 不跟随符号链接，因而该 native 缓存没有枚举 Graphics 子树的风险很高；GifBitmap 又会捕获 native Bitmap 加载异常并替换成空 32x32。修复挂载/缓存后必须重跑，不能放宽占位断言。

诊断现将测试自定义精灵设置固定为 0、sprite_scale 固定为 1，记录源 PNG header 尺寸、真实路径、normal/shiny 路径和尺寸。先直接 Bitmap.new 并与 PNG header 比较，native 错误会原样输出 RAW_BITMAP_FAIL，避免被 GifBitmap 静默吞掉。普通图尺寸改为与已知原图/96→288规则的确定性结果相等，比原来仅大于等于 96 更严格；没有改变生产行为。
