# Android.2 本地测试发布说明

版本0.20.7-android.2 / code2，应用org.kuray.kif，名称KIF Android Test。仅本地测试签名，未上传测试渠道或公开发布。

## 改动

- 保留标题动画内的确认边沿，修复外层再次Input.update丢键。
- Android使用实际渲染字体高度，原TTF、字号、32px行距不变。
- 全资源DEFLATE6并按内容去重，安装仍恢复全部原路径独立文件；由800.14减为708.35MiB，约11.47%，不降音质或删素材。
- 首次来源问答改为诚实独立测试版说明并正常返回人物创建；Android不再复制桌面keybinding并要求重启。
- 构建拒绝遗留.pending/意外assets文件，核对阶段脚本与当前源码，并在构建前后验证源码快照。
- 包含可重跑的字体A/B诊断及portable Windows依赖构建调查/修复。

## 当前产物

| APK | SHA256 | 字节 |
| --- | --- | ---: |
| `KIF-0.20.7-android.2-arm64-network-test.apk` | `67ca0bd614e0b31e546b18467eda9dcbfc9331e121879c6a9750e7bd066220cf` | 742762733 |
| `KIF-0.20.7-android.2-arm64-emulator-network-test.apk` | `7279c3e35af7707bee71d2d003aad1c77ba3476a3a39741e4fa40841f4d95c73` | 742762733 |

产物、SHA侧文件和构建记录都在本worktree `temp/artifacts/`。两包资源版本为 `8c26905a7f60a78cc202278e`。手机包保持原版core，模拟器包只用于已记录的旧ARM翻译器验证，不可把其结果当真机通过。

## 验证状态

- 构建与签名：两包通过；minSdk30、target/compile35、ARM64、当前整体仅4KiB页范围。
- 字体：最终模拟器包原样执行模式0/1，8/8旧裁切、8/8新完整像素；[字体报告](font-rendering-report.md)。
- 资源格式：前一b8包在独立AVD首次解包，23,128路径SHA和2,300别名独立inode实测通过；[资源报告](payload-device-report.md)。最终包后续仅诊断文件改变，实际升级安装和H/G字节保留通过。
- 核心GUI：7279最终包已实际通过标题移动期单C、4种GUI字体、移动、普通融合/拆分、仓库存取、自然野战/捕捉、G槽保存和杀进程后精确队伍/HP/位置冷读。见[本轮GUI报告](gui-regression-report.md)；F/E/SAF随后转Android.3补测，不扩展成最终包全功能验收。
- 主机回归：平台/输入/下载/存档事务检查通过，444个Ruby脚本可编译；构建/去重11组回归及实际Java恢复34断言通过。
- Windows portable原生源码：10个依赖库已有实际产物，Ruby核心已链接、必要扩展恢复构建中。当前APK仍使用固定上游原生库，不宣称整个runtime已从源码重建。

尚无真机、无16KiB整体兼容验收、无完整剧情通关。反向融合/闪光/存档SAF等状态持续以GUI报告实际步骤更新，不预写通过。

## 安装

```powershell
& 'temp/tools/android-sdk/platform-tools/adb.exe' -s emulator-5554 install --no-incremental -r 'temp/artifacts/KIF-0.20.7-android.2-arm64-emulator-network-test.apk'
```

安装前保留存档导出。同测试签名支持原地升级；素材版本独立于saves。首次资源安装需要额外约934MiB解包空间及临时余量，APK变小不等于资源目录同比变小。卸载会删除应用私有数据。
