# IF 融合图鉴文案合并记录

日期：2026-10-22（Asia/Shanghai）。对应 [Issue #3 的 U01](https://github.com/pikechu/kurayshinyrevamp/issues/3)。本次图鉴改动以远程 main（8afd177c）为基线，单独提交到 codex/pokedex-text-update；未重新打包 APK。

## 数据来源与结果

来源为 IF `064a09664aca2e83e28dff436fa37fff72236481` 的 `Data/pokedex/dex.json`，Git blob SHA 为 `502cb28af8207e583fd682a3338687beab642470`。

| 项目 | 数量 |
| --- | ---: |
| 原 KIF 记录，全部保留且顺序不变 | 8,411 |
| IF 原始记录 | 14,807 |
| IF 中已存在或完全重复的有效记录 | 8,212 |
| IF 新增有效、不同的文案 | 6,594 |
| IF 非文本记录，跳过 | 1 |
| 合并结果 | 15,005 |

上一轮“IF 独有 6,596 条”按完整记录多重集合统计，包含一条重复记录和一条非文本记录。本次按完整 JSON 记录判重，同一立绘的不同文案、不同作者继续保留；不改写 KIF 的原文及作者。IF 中数字作者名（例如 `9000`）也保留。

跳过的非文本记录是 `{"sprite":"241.241.png","entry":222,"author":"kiwikelly"}`。上游还有一条 `.realthree` 为 `37.37b.png` 撰写的完全重复记录，只追加一次。

## 自动更新修正

- `RemoteUrls.rb` 的默认图鉴地址由旧 `main/Data/dex.json` 改为 `main/Data/pokedex/dex.json`。
- `updateCustomDexFile` 不再直接覆盖文件，改为解析响应、保留全部本地文案、追加不同的有效记录；旧版、空数组或重复响应均不会删除或重复累积文案。
- HTTP 失败、无效 JSON、本地损坏数据、超限响应或文件替换失败时保留原文件；通过同目录临时文件、flush/fsync 和 rename 完成替换。
- 不使用联机 WireJSON 的 2 MiB 额度处理此素材；采用游戏已有的原生 JSON 解析/编码，支持当前约 3.6 MB 的上游文件。新增图鉴处理上限为 8 MiB、100,000 条。
- 修复的是素材更新流程，不修改存档中的见过/捕获状态或任何玩家精灵。

历史核对：KIF 的 `efb8bc02` 曾导入新版文件，`48fd73a0` 恢复旧文件。更新器一直从旧副本读取，能够覆盖本地新数据；提交说明不足以确定当时回退是手工还是运行后自动更新产生。

## 重复执行与验证

维护命令（Python/浏览器下载来源文件后，传入已核实的 JSON 路径；命令本身不联网）：

```powershell
& '<Ruby 路径>' --disable-gems scripts/pokedex/merge_entries.rb '<上游 JSON 路径>'
& '<Ruby 路径>' --disable-gems tests/pokedex/update_test.rb
& '<Python 路径>' scripts/multiplayer/build.py --check
```

检查结果：

- 数据审计：原 8,411 条逐条原样保留；最终内容等于“原数据 + 上游有效文本”的完整记录集合，15,005 条正文均为字符串。
- 更新回归：27 项通过，覆盖相同立绘不同作者/文案、重复更新、旧响应、防空文件覆盖、原生异常、HTTP 失败、损坏本地文件、Unicode、写入替换失败及 Android 适配器分支。
- 默认 `Game.exe`：隔离 profile `pokedex-merge-native-20261022-r2` 的 12 项检查通过，进程 exit 0。使用真实原生 JSON 和生产图鉴查找方法，读取新增文本及 KIF 独有文本，验证旧文件响应不能降级、无效 JSON 不损坏文件、Unicode 往返和原数据未被测试修改。没有对外网络请求，也未读写真实玩家存档。
- 初次原生探针因嵌入式 Digest 缺少 `.file` 便捷方法失败；探针改用已有 `hexdigest(File.binread(...))` 后通过。两次日志保留于各自的隔离 profile。

日志位于 `temp/multiplayer/pokedex-merge-native-20261022-r2/saves/feature-smoke.log`。本次不宣称已完成人工图鉴页面、全部立绘组合、Android 新 APK 安装或完整跨机器验收。

游戏脚本变化后同时更新 `Data/multiplayer-build.json` 并用真实游戏重新导出租借目录，使源码摘要与服务端可信目录保持一致。

## 独立提交复验

本次仅从远程 main（8afd177c）加入图鉴文件，在独立 worktree 重新通过 27 项更新回归和默认 Game.exe 的 12 项原生检查（profile：pokedex-publish-native-20261022，exit 0）。清单按仓库 LF 源码重新生成，共 507 个输入；租借目录在相同清单下由真实游戏重新导出，12 个候选、48 个招式注册通过（profile：pokedex-publish-catalog-final-20261022，exit 0）。原工作区未提交的 Android、统计、服务端和其他修改未包含在此提交中。
