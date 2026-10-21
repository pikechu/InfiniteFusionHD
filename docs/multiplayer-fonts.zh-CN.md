# 联机中文字体调查与原生验证

日期：2026-10-16。此文记录字体文件来源、许可、当前 Game.exe 的实际行为与局部接入方式；没有修改 Data/Scripts、现有 Fonts、mkxp.json 或主线界面。

## 结论与证据

现有 `Fonts` 只有 Power 系列像素字体。实际 Game.exe 原生探针中，“联机房间交换”六字在 Power Green 渲染后得到同一个像素签名，表示缺字方框；安装在 Windows 系统 Fonts 的微软雅黑/黑体也没有自动成为此 mkxp 运行时的字体。

已下载官方静态 **Noto Sans SC Regular 2.004**，放入独立测试 GameRoot 的 `Fonts` 后，原生 `Font.exist?("Noto Sans SC")` 为 `true`，同六字像素签名全部不同，并实际生成可读中文截图。字体可用于联机菜单、状态页与自绘大厅；应保留单机原字体，并在退出联机入口时恢复作用域设置。

原生验证：

| 项目 | 实际结果 |
| --- | --- |
| 游戏进程 | `Game.exe`，PID 74416，内置 Ruby 3.1.3 |
| 独立 GameRoot | `temp/multiplayer/font-probe` |
| 原生测试脚本 | `temp/multiplayer/font-probe/probe.rb`，只使用 RGSS API，不加载项目脚本或玩家存档 |
| `Font.exist?("Noto Sans SC")` | `true` |
| `Font.exist?("Noto Sans CJK SC")` | `false`：这是另一个字体内部家族名，不能混用 |
| `Font.exist?("Microsoft YaHei")`、`SimHei` | 均 `false` |
| 六字字形签名 | Noto Sans SC：6/6 不同；Power Green：1/6 不同 |
| 完整结果 | `temp/multiplayer/font-probe-native/saves/font-probe.log`，末尾 `PASS` |
| 原生截图 | `temp/multiplayer/font-probe-native/saves/font-probe.png`，已打开检查中文可读 |

![Game.exe 原生中文与原像素字体对照](../temp/multiplayer/font-probe-native/saves/font-probe.png)

该验证证明字体发现和字形绘制可用；完整联机菜单的长文本换行、选项宽度、姓名输入与不同窗口缩放仍需接入后按实际界面验收，不能把单幅字体探针当成所有界面通过。

## 文件与许可

仅下载到工作区 `temp`，没有安装系统字体，也没有把 Windows 自带商业字体复制进项目。

- 文件：`temp/multiplayer/font-probe/NotoSansSC-Regular.otf`
- 长度：8,331,336 字节。
- SHA256：`faa6c9df652116dde789d351359f3d7e5d2285a2b2a1f04a2d7244df706d5ea9`。
- 真实内部名称：家族 `Noto Sans SC`，样式 `Regular`，PostScript 名 `NotoSansSC-Regular`。
- 真实版本：`Version 2.004;hotconv 1.0.118;makeotfexe 2.5.65603`。
- 字体内嵌版权：`© 2014-2021 Adobe (http://www.adobe.com/).`。
- 字体 name 表的许可字段明确为 SIL Open Font License 1.1，许可链接为 `http://scripts.sil.org/OFL`。
- 元数据提取结果：`temp/multiplayer/font-probe/metadata.json`，使用 Python 标准库解析 OpenType name 表，未安装 fontTools 或额外依赖。
- 官方完整许可已下载：`temp/multiplayer/font-probe/OFL.txt`，SHA256 `6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2`。

官方来源：[字体文件页面](https://github.com/notofonts/noto-cjk/blob/main/Sans/SubsetOTF/SC/NotoSansSC-Regular.otf)、[字体二进制](https://raw.githubusercontent.com/notofonts/noto-cjk/main/Sans/SubsetOTF/SC/NotoSansSC-Regular.otf)、[对应 Sans 完整 OFL](https://raw.githubusercontent.com/notofonts/noto-cjk/main/Sans/LICENSE)。许可证允许字体与软件一起分发，须保留版权和许可，字体本身不可单独售卖；此处使用原始字体，不裁剪、不改内部名称。另见 [Noto 官方使用说明](https://notofonts.github.io/noto-docs/website/use/)。

正式打包建议放入：

```text
Fonts/NotoSansSC-Regular.otf
Fonts/OFL-NotoSansSC.txt
Fonts/NOTICE-NotoSansSC.txt
```

`OFL-NotoSansSC.txt` 使用已核实的完整官方许可；`NOTICE` 保留上述 Adobe 版权、字体名称/版本、官方来源和 SHA256。不要只分发字体二进制而遗漏许可。文件名可以保持原样，运行时匹配的是字体内部家族名。

本机确有 `C:/Windows/Fonts/NotoSansSC-VF.ttf`，但为减少变量字体加载和内部命名差异，已采用官方静态 OTF。工作区依赖运行时检出的 Ubuntu、Source Code Pro、DejaVu 等字体不适合作为本次简体中文覆盖方案。

## mkxp 实际字体 API 与加载方式

本项目 `mkxp.json` 已说明 `fontSub` 可替代家族名，但它会影响全游戏，当前不建议用于局部联机功能。mkxp 官方说明字体从游戏或 RTP 的 `Fonts` 目录扫描，找不到字体会用内置字体，通常不会报错；因此“没有异常”不能证明中文显示正确。[mkxp 官方说明](https://github.com/mkxp-z/mkxp-z#fonts)

当前实际 Game.exe 暴露：

```ruby
Font.exist?("Noto Sans SC")
bitmap.font.name = "Noto Sans SC"
bitmap.font.size = 27
Font.default_name = "Noto Sans SC"
System.default_font_family = "Noto Sans SC"
```

最后两个是全局默认，不应随意用于只更换联机 UI。探针枚举的 `Font` 类 API 没有运行时注册字体方法；添加文件后应重新启动游戏，让 mkxp 启动扫描发现字体。不要假设调用 Windows `AddFontResource` 就能更新 mkxp 内部字体集。API 与字体选择逻辑亦可核对 [mkxp Font binding](https://raw.githubusercontent.com/mkxp-z/mkxp-z/dev/binding/font-binding.cpp) 和 [字体实现](https://raw.githubusercontent.com/mkxp-z/mkxp-z/dev/src/display/font.cpp)。

字体数组如 `["Power Green", "Noto Sans SC"]` 只会选择第一个存在的家族，不会按每个字符回退；只要 Power Green 存在，中文仍然缺字。联机区域应明确选择 Noto Sans SC。

### 自绘界面

自绘大厅、回放画布等可直接只设置自身 bitmap：

```ruby
raise KIFMultiplayer::Error, "Missing bundled Noto Sans SC font" unless Font.exist?("Noto Sans SC")
bitmap.font.name = "Noto Sans SC"
bitmap.font.size = 27
```

这不会修改主线默认字体。宽度与换行应使用该字体的 `text_size`，不能继续按像素字体的固定字符宽估计。

### 原生消息与选择窗口

本项目 `pbSetSystemFont`、`pbSetSmallFont`、`pbSetNarrowFont` 会重新使用 `MessageConfig` 缓存的字体名，仅修改 `Font.default_name` 不够。联机最外层入口可保存并临时设置三个名称，确保异常与取消也会恢复：

```ruby
def with_multiplayer_fonts
  raise KIFMultiplayer::Error, "Missing bundled Noto Sans SC font" unless Font.exist?("Noto Sans SC")
  old = [MessageConfig.pbGetSystemFontName,
         MessageConfig.pbGetSmallFontName,
         MessageConfig.pbGetNarrowFontName,
         Font.default_name]
  begin
    MessageConfig.pbSetSystemFontName("Noto Sans SC")
    MessageConfig.pbSetSmallFontName("Noto Sans SC")
    MessageConfig.pbSetNarrowFontName("Noto Sans SC")
    Font.default_name = "Noto Sans SC"
    yield
  ensure
    MessageConfig.pbSetSystemFontName(old[0])
    MessageConfig.pbSetSmallFontName(old[1])
    MessageConfig.pbSetNarrowFontName(old[2])
    Font.default_name = old[3]
  end
end
```

已接入 `002_UI.rb` 的 `KIFMultiplayer.with_ui_fonts`，包住联机入口及子页面，正常/异常都恢复三个MessageConfig字体名与Font.default_name；新增回归还验证未安装字体时的安全路径。当前不改字号。网络线程不修改字体。该scope还暂缓旧native素材下载并恢复原设置，避免与安全Socket worker并发触发旧HTTP的GVL错误。

## 可复现原生验证

下载和许可已保存，探针的独立 GameRoot 下有 `Fonts/NotoSansSC-Regular.otf` 与原 Power Green 对照文件。无需修改项目：

```powershell
& scripts/multiplayer/start-client.ps1 `
  -Profile font-probe-native `
  -GameRoot D:/others/kurayshinyrevamp/temp/multiplayer/font-probe `
  -CustomScript D:/others/kurayshinyrevamp/temp/multiplayer/font-probe/probe.rb
```

验证完成后进程自行退出。正式接入后还需检查：主菜单所有中文可读；两人房间、战斗等候、完整报价与错误提示的长文本不越界；大厅和回放中文名字正常；取消/异常返回后单机字体及字号完全恢复；已有进程重启后才做新字体验收。

## 005_Gym 独立只读 CR

本轮未发现会导致崩溃、原个体损失或重复奖励的 P1。临时双方队伍在 `BattleIsolation` 中创建；`@internalBattle=false` 使原引擎拒绝背包道具；经验、金钱、捕获和普通战后流程已覆盖以保护主线。`GymSession` 先保存固定战报及 request_id，响应丢失后重发原上报，胜利领取按服务端账号加道馆编号唯一。异常恢复把未完成挑战标为异常，原先胜负不能被改成胜利。该只读 CR 不代替人工界面验收；后续 011/012 将另行审查。
