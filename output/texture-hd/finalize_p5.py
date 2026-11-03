"""Publish the verified full-P5 result into existing local progress documents."""
from resume_p2_menu import ROOT, OUT, read, write, digest


def main():
    verification=read(OUT/'p5-evidence/checkpoint-verification.json')
    assert verification['status']=='passed' and verification['files']==1850 and verification['remaining']==0
    plan=read(OUT/'execution-plan/plan.json');index={b['id']:b for b in plan['batch_index']};applied={}
    for b in plan['batch_index']:
        assert b['status']=='completed'
        path=OUT/b['id']/'manifest.json'
        applied[b['id']]=len(read(path)['entries']) if path.exists() else 0
        assert applied[b['id']]<=b['file_count']
        b.update(applied_files=applied[b['id']],preserved_files=b['file_count']-applied[b['id']])
    assert sum(applied.values())+plan['already_applied_images']==268
    for priority in plan['priorities']:
        selected=[b for b in plan['batch_index'] if b['priority']==priority['priority']]
        total=sum(b['file_count'] for b in selected);count=sum(applied[b['id']] for b in selected)
        priority.update(status='completed',completed_files=total,applied_files=count,preserved_files=total-count,remaining_files=0)
    for stage in plan['stages']:
        total=sum(index[b]['file_count'] for b in stage['batch_ids']);count=sum(applied[b] for b in stage['batch_ids'])
        stage.update(status='completed',completed_files=total,applied_files=count,preserved_files=total-count)
    plan.update(status='completed',next_batch=None,completed_priorities=['P1','P2','P3','P4','P5'],execution_updated_date='2026-11-03',
                execution_inventory_sha256=digest(OUT/'inventory.json'),execution_summary=verification['global_inventory'],
                planning_snapshot_note='already_applied_images, remaining_images and inventory_sha256 retain the original planning snapshot; current totals are execution_summary and per-batch receipts.')
    write(OUT/'execution-plan/plan.json',plan)
    write(OUT/'p5-work/resume.json',{'status':'completed','completed_on':'2026-11-03','completed_through':'batch-857','next_batch':None,
          'completed_files':1850,'applied_files':0,'preserved_files':1850,'candidate_pending_review':[],'ready_pending_application':[],
          'verification':'output/texture-hd/p5-evidence/checkpoint-verification.json','cleanup':'output/texture-hd/p5-evidence/cleanup.json',
          'scope':'P5 and all fixed batches complete; future new assets require new batch numbers. Full gameplay and Android release/device validation are outside this result.'})
    summary='''## P5 全部完成（2026-11-03）

**第 817～857 批共 1,850 / 1,850 张，全部完成核查并保留原图；新增高清化应用 0 张，待验收候选 0 张。** 已有像素轮廓、功能切片及作者源稿没有确定的原尺寸重绘收益；旧版/未绑定来源保留各自历史用途，没有删除或改写原文件。

| P5 范围 | 文件数 | 结果 |
| --- | ---: | --- |
| 第 817～824 批：备份、旧版与测试 | 366 | 全部保留 |
| 第 825～852 批：96×96 源素材集合 | 1,344 | 全部保留 |
| 第 853～857 批：长条与杂项 | 140 | 全部保留 |

已归档 245 张来源的同尺寸精确像素匹配、533 张来源与现有文件的精确 3 倍最近邻关系，以及集合内部其他整数缩放关系。**最近邻放大不计为 AI 高清化。** 92 张逐项审查页及 3 张集合阶段页覆盖原始内容、独立姿态、部件、文字和变体；高图集阶段样本不冒称全部地图拼接验收，未绑定条带不编造播放时长。

实际运行证据及边界：

- [源码/原始数据引用审查](p5-evidence/remaining/reference-audit.json)区分限定路径、短名称提示和本地化登记；[860 个可解析序列化文件及实际资源声明](p5-evidence/remaining/reference-native-review.json)未选择后续备用图块或动画来源。消息目录与 7 个非 Marshal/旧类文件采用原始字节扫描。`test`、`OutdoorLight`、融合编号或映射表登记不直接计为普通图片选择。
- [原生媒体验收](p5-evidence/remaining/media-native-review.json)：后续 1,754 张全部按原尺寸解码，230 个旧背景/地台实际绘制；两张旧行走图覆盖全部方向/格位。1,192 张规则源图进入前后面兼容组件，共 2,384 组、119,200 个选择/目标周期状态；固定基线物种及显式自定义文件不等同于原始作者图的正式物种绑定。
- 1,032 份原生 96→288 输出的透明度与可见 RGB 已逐像素核对。`24 by _sadfroggy.PNG` 存在既有的大写扩展名解析回退，工厂回退未计为正确来源绑定；其保留大小写的显式加载另行验证。文件名、源图和游戏逻辑均未因此改写。
- `debug_message.png` 仍由精灵定位编辑器使用，实际中英文 SpritePositioner 构建及物种选择通过，未编辑或保存度量。第 817 批 `fly copy.png` 的两条热风图集声明及四组完整播放保留在[历史证据](p5-evidence/batch-817/effects-review.json)，没有将无可见图格使用的声明当作实际绘图。
- 当前图像/消费脚本依赖和 10 对本地化图像哈希一致。并行校对进度文件及历史中文文本库版本差异只作观察记录，未覆盖外部改动，也未纳入本特性分支的源码/本地化提交。

全部 1,850 张当前文件、原图和 delivery 副本的字节、尺寸、RGBA 及透明通道一致。见[全量恢复点复核](p5-evidence/checkpoint-verification.json)、[P5 进度](p5-progress.json)、[恢复记录](p5-work/resume.json)与[清理记录](p5-evidence/cleanup.json)。本轮测试进程、临时配置、原始日志和缩放导出帧已清理，原图、正式证据及共享安装的工具保留。

**既定 18,665 张计划已全部结项：267 张高清化并应用、1 张仅修复图片编码、18,397 张保留，待处理 0 张。** 完成不表示所有图片均重绘；完整游玩、Android 实机及最终发布包尚未验证。以后新增素材追加新批号，不更改已有批次。

'''
    path=OUT/'README.zh-CN.md';text=path.read_text(encoding='utf-8')
    if '## P5 全部完成（2026-11-03）' not in text:text=text[:text.index('\n')+1]+'\n'+summary+text[text.index('\n')+1:]
    text=text.replace('## P5 第 818 批已完成（2026-11-03）','## P5 第 818 批历史保存点（2026-11-03）')
    text=text.replace('## P5 第 817 批已完成（2026-11-03）','## P5 第 817 批历史保存点（2026-11-03）')
    path.write_text(text,encoding='utf-8')
    line='2026-11-03：P1～P5 全部完成，固定批次第 5～857 批均已结项。P5 共 1,850 张全部保留；全局 267 张高清化应用、1 张仅修复编码、18,397 张保留、0 张待处理。完成包含有证据的保留决定，详见[当前报告](../README.zh-CN.md)。'
    for name in ('execution-plan/README.zh-CN.md','execution-plan/stage-summary.zh-CN.md'):
        path=OUT/name;lines=path.read_text(encoding='utf-8').splitlines()
        lines=[line if old.startswith('2026-11-03：P1～P4 已完成；') else old for old in lines]
        lines=[('当前 P1～P5 的所有固定批次均为 completed，next_batch=null。原始计划快照字段保留规划时数量，当前数量以 execution_summary、inventory.json 和逐批验收为准。无后台任务或定时执行；新增图片追加新批号。' if old.startswith('当前 P1～P4（第 5～816 批）') else old) for old in lines]
        path.write_text('\n'.join(lines)+'\n',encoding='utf-8')
    print({'status':'completed','P5_files':1850,'global':verification['global_inventory']},flush=True)


if __name__=='__main__':main()
