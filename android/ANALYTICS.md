# Android 统计适配

本目录的 `Analytics.java`、`AnalyticsProtocol.java` 与协议测试属于独立统计模块。Android 游戏外壳和构建工具现已合入 main，合并后的 Java 编译和协议检查已通过；生命周期、玩家开关和配置资产接线仍需单独完成，当前没有因源码合并而启用 Android 统计。Windows 统计和 Matomo/下载网关可独立使用，见 [统计部署说明](../server/analytics/README.zh-CN.md)。

需要接入 Android 统计时，先在仓库根目录检查早期外壳对应的参考补丁；新版外壳上下文已变化，应按下列接线要求合并并另做设备验收：

```powershell
git apply --check android/analytics-integration.patch
git apply android/analytics-integration.patch
```

补丁以现有移植外壳为基础，只增加游戏前台生命周期调用、启动器统计开关、INTERNET 权限、APK 中的公共配置复制，以及协议测试入口。若移植代码已包含这些调用，不重复应用；若上下文变化，按以下接线要求逐项合并。

- 游戏成功进入前台时调用 `Analytics.onGameResume(this)`，暂停和销毁时调用 `Analytics.onGamePause()`；安装器、资源修复、runtime/game smoke 不计入活跃。
- 启动器的存档管理页显示 `isConfigured` / `isUsageEnabled` / `setUsageEnabled` 开关及其数据说明。
- 允许 INTERNET，保留 `usesCleartextTraffic=false`；不添加位置、设备识别码权限。原有 Ruby 网络入口继续通过平台适配器阻止不验证证书的原生 HTTP，统计只使用 Java 的 HTTPS。
- 打包时把 `Data/analytics.json` 复制为 APK assets 根目录中的 `analytics.json`。只允许公共配置字段，绝不包含服务端 token；以实际 payload manifest 的 `runtimeOnly` 值强制关闭探针 APK 的统计。

Java 适配器只依赖 Android 系统 API 与同目录的 `AnalyticsProtocol`，不依赖 Ruby 联机模块或第三方 SDK。关闭统计会移除本机随机安装 ID。配置默认关闭，启用前应完成 Matomo 站点和维度配置。

纯协议测试可使用任意 JDK 8+，不要求 Android SDK：

```powershell
javac -encoding UTF-8 -d temp/analytics-java android/app/src/main/java/org/kuray/kif/AnalyticsProtocol.java android/tests/java/AnalyticsProtocolHostTest.java
java -cp temp/analytics-java org.kuray.kif.AnalyticsProtocolHostTest
```

完整 `Analytics.java` 的编译需要 Android SDK；生命周期与玩家开关的设备验收仍应在接线后的实际 APK 上进行。
