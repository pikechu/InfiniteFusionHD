# 字体裁切设备对照（Android.2）

2026-10-20，emulator-5554，Android 11/API30 x86_64 + ARM64 native bridge，4 KiB pages。

## 实际结论

`fontHeightReporting=0` 的 8 种字体全部复现字形下半裁切；模式 1 的 8 种字体都恢复完整像素，与 64px 高原生绘制参考一致。所有字体均由 `Font.exist?` 确认存在。测试字符串为 `Agjpqyé`，包含下伸部与带音符字符。

| 字体 / 字号 | 旧报告高度 | 新报告高度 | 旧绘制/参考像素 | 新绘制/参考像素 |
| --- | ---: | ---: | ---: | ---: |
| Power Green / 29 | 12 | 22 | 326 / 680 | 680 / 680 |
| Power Green Small / 25 | 11 | 18 | 182 / 344 | 344 / 344 |
| Power Green Narrow / 29 | 12 | 22 | 282 / 592 | 592 / 592 |
| Power Red and Green / 26 | 9 | 20 | 212 / 611 | 611 / 611 |
| Power Red and Blue / 24 | 13 | 21 | 229 / 471 | 471 / 471 |
| Power Red and Blue Intl / 24 | 12 | 18 | 310 / 484 | 484 / 484 |
| Power Clear / 29 | 12 | 22 | 319 / 668 | 668 / 668 |
| Power Clear Bold / 29 | 15 | 28 | 509 / 884 | 884 / 884 |

采用真实脚本加载顺序，跳过生产 Main 场景循环；最终 Bitmap.draw_text 来自后加载 `102_DemICE's Tutor.net/Tutor.net.rb:24`。参考调用保存的原生 `mkxp_draw_text`，实际调用最终游戏 wrapper；扫描透明像素数及垂直占用范围，而非只检查构建或日志标签。新模式最大实际字形占用行号22，加游戏4px偏移和2px阴影仍在32px菜单行内；实际多行消息和四种菜单字体的视觉回归另见GUI报告，不能由本探针替代。

## 证据与限制

- APK：`b8e19919adc12542391444ce750f3df9a4854d42ff9a19969aa013fe6665e2c7`，0.20.7-android.2/code2，独立完整包。
- 该次 APK 内的初版诊断有加载作用域及 RGSS1 Font.shadow 可选接口问题；已保留失败日志。为快速验证原生指标，只替换了 app 私有 content 根的 **android-font-smoke.rb 诊断文件**，完整 Ruby 游戏源码、TTF、原生库和 Java 配置未修改；根任务正在重新打包这份已通过的诊断源。
- `diagnostic-override.json`、`diagnostic-rgss1-override.json` 记录替换前后 SHA；失败分别保留为 `namespace-failure-mode-0-logcat.txt`、`rgss1-shadow-failure-mode-0-logcat.txt`。没有将失败覆盖成成功。
- 正常游戏入口不加载这个独立 customScript；每个模式都新建游戏进程，未读写玩家槽。当前结果是字体配置/绘制验证，尚不构成最终 APK 的完整GUI验收。
- 首次完整资源安装耗时276828ms，升级前后 File H 的原始字节一致。安装/启动期间出现过 System UI ANR，选择 Wait 后继续；原图已保留。测试负载及宿主I/O不可推断真机性能。

原始 JSON、完整无裁切参考 PNG、物理屏幕截图、logcat 位于 `temp/evidence/font-metrics-android2/`。每张PNG左列为64px原生参考，右列为游戏最终绘制。模式0右列明显截断；模式1内容完整。

复现：安装含修正探针的完整APK后，在本任务工作区运行：

```powershell
& '<portable Python>' scripts/android/check_fonts.py --serial emulator-5554
```

只在明确启动 fontSmoke 时运行；普通 Launcher 会恢复默认模式1和正常游戏入口。

## 最终完整 APK 复验

APK `7279c3e35af7707bee71d2d003aad1c77ba3476a3a39741e4fa40841f4d95c73` / payload `8c26905a7f60a78cc202278e` 已于同日升级安装到5554。
本次没有替换任何已安装脚本或资源，原包内诊断直接执行，模式0再次0/8完整、模式1再次8/8完整，所有数值与上表一致。升级后的H基线和G隔离槽分别仍为c4e4ae...23b3b及f5fa15...da4e8，逐字节核验通过。

本轮原始证据为 `temp/evidence/font-metrics-final-7279/`，包括新的launch、JSON、原生PNG、物理screencap、完整logcat和upgrade-save-integrity.json；与前一轮hotfix诊断证据分开。后续正常GUI测试使用此最终包，见GUI回归报告。
