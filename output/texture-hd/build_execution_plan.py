"""Freeze a file-complete execution plan. Does not edit images or run generation."""

import hashlib
import json
import math
import re
import subprocess
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
DEST = OUT / "execution-plan"

# id, priority, title, method, maximum files, prerequisite stage
STAGES = [
    ("ground_pilot", "P1", "战斗地台试制：桥面、山地、沼泽、暗洞、冰洞、水下", "ground", 12, None),
    ("ground", "P1", "其余战斗地台：按环境合并敌我两侧与昼夜版本", "ground", 24, "ground_pilot"),
    ("message", "P1", "战斗消息条与背景衔接", "ui", 16, "ground_pilot"),
    ("tiles_pilot", "P1", "地图图块试制：商店室内", "tileset", 1, None),
    ("tiles_core", "P1", "室外与室内主图集", "tileset", 1, "tiles_pilot"),
    ("tiles_other", "P1", "其余地图图集", "tileset", 1, "tiles_pilot"),
    ("auto_pilot", "P1", "自动图块试制：道路、泥地、砂地、草地", "autotile", 4, "tiles_pilot"),
    ("auto_ground", "P1", "其余静态自动图块", "autotile", 6, "auto_pilot"),
    ("auto_water", "P1", "动态自动图块：水面、瀑布、熔岩及水流", "autotile", 4, "auto_pilot"),
    ("ui_battle", "P2", "战斗界面、血条、按钮、状态与属性图", "ui", 24, None),
    ("ui_party", "P2", "队伍、背包、摘要与通用菜单", "ui", 24, "ui_battle"),
    ("ui_dex", "P2", "图鉴、仓库与命名界面", "ui", 24, "ui_battle"),
    ("ui_map", "P2", "地区地图、导航、帮助与训练师卡", "ui", 24, "ui_battle"),
    ("titles", "P2", "标题、载入与启动界面", "ui", 20, "ui_battle"),
    ("panorama", "P2", "全景与场景背景", "background", 12, None),
    ("player_pilot", "P2", "主角身体试制：1 号身体全动作及训练师图", "character", 16, None),
    ("player_body", "P2", "其余主角身体与冲浪底层", "character", 20, "player_pilot"),
    ("starter", "P2", "初始睡衣、Red/Leaf 发型与配套服装", "wearable", 24, "player_body"),
    ("pokemon_pilot", "P2", "默认宝可梦试制：妙蛙种子、小火龙、杰尼龟", "pokemon", 6, None),
    ("pokemon_main", "P2", "默认宝可梦战斗图：按编号推进", "pokemon", 32, "pokemon_pilot"),
    ("trainer", "P2", "训练师战斗立绘与背面图", "character", 24, "player_pilot"),
    ("npc", "P3", "地图人物、NPC 与其他行走精灵", "character", 20, "player_pilot"),
    ("follower", "P3", "跟随宝可梦：按物种与形态分组", "character", 20, "player_pilot"),
    ("outfit", "P3", "衣服、头发、帽子与其他玩家分层素材", "wearable", 24, "starter"),
    ("pokemon_alt", "P3", "宝可梦替换画法与其他静态战斗图", "pokemon", 32, "pokemon_main"),
    ("special", "P3", "特殊形态、三重融合、蛋与替身", "pokemon", 24, "pokemon_main"),
    ("ui_other", "P3", "小游戏、开场、装饰与其他界面", "ui", 24, "ui_battle"),
    ("icons", "P4", "宝可梦小图标与道具图标", "icon", 48, "pokemon_pilot"),
    ("footprint", "P4", "足迹、阴影、小型符号与功能遮罩", "mask", 64, None),
    ("windows", "P4", "窗口皮肤与边框切片", "windowskin", 16, "ui_battle"),
    ("effects", "P4", "招式与战斗特效帧表", "effect", 8, None),
    ("weather", "P4", "天气、雾效、背景动画与战斗转场", "effect", 8, "effects"),
    ("animated", "P4", "长动画条、动态精灵与 GIF", "animated", 2, "pokemon_pilot"),
    ("archive", "P5", "备份、旧版、备用与测试目录：先核对用途", "audit", 48, None),
    ("source96", "P5", "96×96 源素材集合：先核对与运行素材的关系", "audit", 48, None),
    ("misc", "P5", "杂项、素材集合与用途待确认图片", "audit", 32, None),
]
CONFIG = {row[0]: row for row in STAGES}
GROUND_PILOT = {"bridge", "mountain", "swamp", "cavedark", "caveice", "underwater"}
OLD_PARTS = {"backup", "backups", "unused", "playerbase_orig", "olddatabox"}
OLD_NAME = re.compile(r"(?:^|[ _.-])(old|backup|original|copy|copie|unused|test|debug|dev)(?:$|[ _.-])", re.I)

METHODS = {
    "ground": "逐图 AI 补绘地面材质；敌我两侧同批，保留原始轮廓、位置与透明通道；与现有背景合成检查。",
    "tileset": "先核对地图引用和 32×32 源图块网格，分片补绘并原位回填；保护拼接边、图块编号、遮挡和末尾不足一行的像素。",
    "autotile": "先确认原拼接规则和动画帧布局，逐块或逐帧处理；检查角、边、环绕拼接和动画循环。",
    "ui": "先识别文字、按钮、图标和切片区，保护文字原像素与布局，仅增强背景和装饰；中文与原版同步检查。",
    "background": "先核对是否滚动或重复平铺，再以原图补绘；保护构图、地平线与平铺接缝。",
    "character": "先核对实际动作/方向/帧布局，逐帧补绘并回填；锁定脚底、主体锚点、方向和动作，连续播放验收。",
    "wearable": "同一套衣服、头发或帽子的全部动作作为一组；用原主角身体叠穿验收，保护 80×80 等实际分格及偏移。",
    "pokemon": "保持物种、姿态、主体大小、定位、透明轮廓和配色；沿用试制风格，正背面、形态和闪光变色需验证。",
    "icon": "以原尺寸可读性为目标，先试小样再补绘；保留符号含义、帧布局及透明边，不为增加纹理而强改。",
    "mask": "先识别足迹、阴影和遮罩用途；默认保留语义、透明度和灰阶，只有存在可见问题且有依据时才修复。",
    "windowskin": "按引擎实际边框切片区域处理；保持边距、文字背景、箭头、光标和重复边的连接。",
    "effect": "核对帧格、切片、透明度、色调与混合方式，逐帧增强；验收播放速度、闪烁、遮挡与循环。",
    "animated": "确认帧数、帧宽、顺序与时长，逐帧补绘、原位组装；保留 PNG 条带/GIF 格式及循环信息，连续播放检查。",
    "audit": "先追踪运行/地图/界面引用并比对重复图；确有使用才选择对应处理流程，未使用或无收益则保留并记录依据，不删除原图。",
}

COMMON_ACCEPTANCE = [
    "核对本批全部来源文件、计划时尺寸及修改记录；发现外部变动先核对差异，不能覆盖后续工作。",
    "每张保留原文件名、原始宽高、格式用途和逐像素透明通道；先保存原图 SHA-256、备份与生成记录。",
    "逐张查看原尺寸前后对比；不新增、移除或移动原有主体、文字、按钮、图块与帧。",
    "使用相应游戏场景或连续动画验收；仅能加载图片不能替代交互、拼接或动画验证。",
    "核对应用文件与清单 SHA-256，更新库存和本批结果；保留无收益素材时记录原因，不伪称已重绘。",
]
METHOD_ACCEPTANCE = {
    "ground": ["敌我两侧与原背景合成，核对地台锚点、透明轮廓、覆盖区域和环境配色。"],
    "tileset": ["完整图集原尺寸和 32×32 网格不变，保护尾行；实地图检查道路/墙体/屋顶接缝、遮挡与动画关联。"],
    "autotile": ["检查所有拼接角边及 3×3 等相邻示例；动态资源连续播放一个完整循环。"],
    "ui": ["核对文字逐字内容、字号与位置、按钮区域、光标、选中状态和深浅主题；中英文分别显示。"],
    "background": ["核对场景构图与滚动/平铺接缝，若带文字须保护原文字。"],
    "character": ["核对全部方向与动作，连续播放；脚底锚点和各格位置不变，穿戴层叠合正确。"],
    "wearable": ["同套动作图逐帧叠穿，核对头发/帽子/衣服/身体遮挡和偏移；商城图同步核对校验清单。"],
    "pokemon": ["在实际战斗尺寸下核对物种识别、姿态、正背面关系、配色及闪光变色；不以图片清晰度代替身份一致性。"],
    "icon": ["原尺寸下确认小图可辨识、帧数和符号含义不变；没有可见收益则保留原图并记录。"],
    "mask": ["核对足迹/阴影/遮罩的灰阶、透明度和实际渲染用途；不将功能图添加装饰纹理。"],
    "windowskin": ["小窗、大窗、多行文本窗口、选项与光标实际显示，检查所有切片边界和平铺边。"],
    "effect": ["核对格数、顺序、混合与透明度；实际播放检查闪烁、速度、遮挡和循环。"],
    "animated": ["全部帧与原始时长、顺序和循环一致；完整连续播放，确认无跳帧、抖动或帧间身份变化。"],
    "audit": ["保存引用/重复关系证据；需要时沿对应方法改造，不使用或无收益时原样保留，不删除、不擅自替换备份。"],
}


def natural(value):
    return tuple((1, int(part)) if part.isdigit() else (0, part.casefold()) for part in re.split(r"(\d+)", value))


def choose_stage(source, size):
    p = Path(source)
    parts = p.parts
    category, name = parts[1], p.stem.casefold()
    if any(part.casefold() in OLD_PARTS for part in parts) or OLD_NAME.search(name):
        return "archive"
    if category == "BaseSprites" and "96x96 sprites + assets" in parts:
        return "source96"
    w, h = size
    if category in {"Animated Sprites", "Triples", "BaseSprites", "Battlers"} and (p.suffix.lower() == ".gif" or (w > 4*h and h >= 128)):
        return "animated"
    if category == "Battlebacks":
        if parts[2] in {"enemybase", "playerbase"}:
            return "ground_pilot" if name in GROUND_PILOT else "ground"
        if len(parts) == 3:
            return "message"
        return "weather"
    if category == "Tilesets":
        if name == "mart interior":
            return "tiles_pilot"
        return "tiles_core" if name in {"outdoor", "indoor", "outdoor2"} else "tiles_other"
    if category == "Autotiles":
        if p.suffix.lower() != ".png" or h > 4096:
            return "misc"
        if name in {"brick path", "dirt", "sand", "light grass"}:
            return "auto_pilot"
        return "auto_ground" if w <= 96 else "auto_water"
    if category in {"Titles", "Panoramas"}:
        return "titles" if category == "Titles" else "panorama"
    if category == "Characters":
        if "Followers" in parts:
            return "follower"
        if parts[2:4] == ("player", "base"):
            return "player_pilot" if (parts[-2] == "1" or name == "trainer_1") else "player_body"
        if parts[2:4] == ("player", "surf_base"):
            return "player_body"
        if len(parts) > 4 and parts[2] == "player":
            return "starter" if parts[4].casefold() in {"pikajamas", "red", "leaf", "ash"} else "outfit"
        if parts[2] == "player":
            return "outfit"
        return "npc"
    if category in {"Trainers", "Alternate Trainers"}:
        return "trainer" if category == "Trainers" else "npc"
    if category == "BaseSprites":
        if re.fullmatch(r"\d+", name):
            return "pokemon_pilot" if int(name) in {1, 4, 7} else "pokemon_main"
        return "pokemon_alt"
    if category == "Battlers":
        if len(parts) > 3 and parts[2].isdigit() and re.fullmatch(r"\d+", name):
            return "pokemon_pilot" if int(name) in {1, 4, 7} else "pokemon_main"
        return "special"
    if category in {"Eggs", "Triples", "Jokes", "substitute.png", "substitute_back.png"}:
        return "special"
    if category in {"Icons", "Pokemon", "Unfused Icons", "Items"}:
        return "footprint" if "Footprints" in parts or "Shadow" in parts else "icons"
    if category == "Windowskins":
        return "windows"
    if category in {"Animations", "Battle animations"}:
        return "effects"
    if category in {"Weather", "Fogs", "Transitions"}:
        return "weather"
    if category == "Pictures":
        scene = parts[2].casefold() if len(parts) > 3 else ""
        if scene in {"battle", "battlegui"} or any(word in name for word in ("battle", "status", "type", "movesel", "ability")):
            return "ui_battle"
        if scene in {"party", "bag", "summary", "gs summary backgrounds", "universal", "ready menu", "goldsilver menu"} or re.match(r"(?:bag|party|summary|menu|option)", name):
            return "ui_party"
        if scene in {"pokedex", "pokedex dark theme", "storage", "boxes", "naming"} or re.match(r"(?:pokedex|naming|box)", name):
            return "ui_dex"
        if scene in {"map", "pokegear", "trainer card", "controls help", "tutor.net"} or any(word in name for word in ("mapregion", "pokegear", "controls", "trainer_application", "leagueform", "leagueletter")):
            return "ui_map"
        return "ui_other"
    return "misc"


def family_key(source, stage):
    p = Path(source)
    if stage.startswith("ground"):
        return re.sub(r"_(eve|night)$", "", p.stem.casefold())
    if stage in {"player_pilot", "player_body"}:
        if "/base/overworld/" in source:
            return "body-" + p.parent.name
        if "/base/trainer/" in source:
            return "body-" + p.stem.removeprefix("trainer_")
    if stage in {"starter", "outfit"}:
        return "/".join(p.parts[:5])
    if stage in {"pokemon_pilot", "pokemon_main"}:
        return p.stem.lstrip("0") or "0"
    if stage in {"npc", "follower", "trainer"}:
        return p.parent.as_posix() + "/" + re.sub(r"(?:_back|_\d+|s)$", "", p.stem)
    if stage in {"icons", "footprint", "effects", "weather", "ui_battle", "ui_party", "ui_dex", "ui_map", "ui_other", "archive", "source96", "misc"}:
        return p.parent.as_posix()
    return source


def main():
    inventory_bytes = (OUT / "inventory.json").read_bytes()
    inventory = json.loads(inventory_bytes)
    pending = {a["path"]: a for a in inventory["assets"] if a["status"] == "pending"}
    current = {Path(p).as_posix() for p in subprocess.check_output(["rg", "--files", "Graphics"], cwd=ROOT, text=True, encoding="utf-8").splitlines() if Path(p).suffix.lower() in {".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp"}}
    assert current == {a["path"] for a in inventory["assets"]}, "Inventory changed; refresh before freezing the plan"
    assert not (DEST / "plan.json").exists(), "A plan already exists; preserve its batch numbering"
    localized = json.loads((ROOT / "Data/localization/zh-CN-images.json").read_text(encoding="utf-8"))["images"]
    reverse = {row["path"]: source for source, row in localized.items()}
    assert len(reverse) == len(localized), "Shared translations need explicit grouping"
    shop = json.loads((ROOT / "Data/shop/catalog.json").read_text(encoding="utf-8")).get("assets", {})
    units = {}
    for source, asset in pending.items():
        canonical = reverse.get(source, source)
        units.setdefault(canonical, []).append(asset)
    buckets = defaultdict(list)
    for source, assets in units.items():
        source_asset = pending.get(source) or assets[0]
        stage = choose_stage(source, source_asset["size"])
        buckets[stage].append((source, sorted(assets, key=lambda a: a["path"])))

    batches, stage_ids = [], defaultdict(list)
    for stage, priority, title, method, maximum, prerequisite in STAGES:
        ordered = sorted(buckets[stage], key=lambda unit: (natural(family_key(unit[0], stage)), natural(unit[0])))
        # Keep paired language files and enemy/player pairs together. Whole wardrobes
        # stay together when they fit; very large families continue in the next batch.
        families = defaultdict(list)
        for unit in ordered:
            families[family_key(unit[0], stage)].append(unit)
        packed, pack = [], []
        for family in families.values():
            family_count = sum(len(unit[1]) for unit in family)
            if family_count <= maximum:
                if pack and sum(len(unit[1]) for unit in pack) + family_count > maximum:
                    packed.append(pack)
                    pack = []
                pack.extend(family)
            else:
                for unit in family:
                    if pack and sum(len(item[1]) for item in pack) + len(unit[1]) > maximum:
                        packed.append(pack)
                        pack = []
                    pack.append(unit)
        if pack:
            packed.append(pack)
        for index, group in enumerate(packed, 1):
            number = len(batches) + 5
            batch_id = f"batch-{number:03}"
            entries, manifests = [], set()
            for canonical, group_assets in group:
                for asset in group_assets:
                    source = asset["path"]
                    stat = (ROOT / source).stat()
                    w, h = asset["size"]
                    entry = {"source": source, "size": [w, h], "source_bytes": stat.st_size,
                             "source_mtime_ns": stat.st_mtime_ns, "canonical_source": canonical}
                    if source in reverse or canonical in localized:
                        manifests.add("Data/localization/zh-CN-images.json")
                        entry["language_pair"] = {"original": canonical, "chinese": localized[canonical]["path"]}
                    if source in shop:
                        manifests.add("Data/shop/catalog.json")
                        entry["catalog_pinned"] = True
                    if method == "tileset":
                        entry["internal_work"] = {"tile_grid": [32, 32], "suggested_strip_height": 512,
                                                  "strip_count": math.ceil(h/512), "tail_rows": h % 32}
                    if method == "animated":
                        entry["layout_must_be_read_from_loader"] = True
                    entries.append(entry)
            deps = list(stage_ids[prerequisite]) if prerequisite else []
            if index > 1:
                deps.append(stage_ids[stage][-1])
            batch = {"id": batch_id, "number": number, "priority": priority, "stage": stage,
                     "title": title + (f"（{index}/{len(packed)}）" if len(packed) > 1 else ""),
                     "status": "needs_usage_audit" if method == "audit" else "planned",
                     "action": "audit_then_enhance_if_used" if method == "audit" else "enhance_with_validation",
                     "method": method, "processing_notes": METHODS[method], "depends_on": deps,
                     "acceptance": COMMON_ACCEPTANCE + METHOD_ACCEPTANCE[method],
                     "file_count": len(entries), "catalogs_to_check_and_update": sorted(manifests),
                     "destination": f"output/texture-hd/{batch_id}", "entries": entries}
            assert len(entries) <= maximum, (batch_id, len(entries), maximum)
            batches.append(batch)
            stage_ids[stage].append(batch_id)

    assigned = [entry["source"] for batch in batches for entry in batch["entries"]]
    assert Counter(assigned) == Counter({source: 1 for source in pending}), "Every pending image must appear exactly once"
    assert not set(assigned) & {a["path"] for a in inventory["assets"] if a["status"] == "applied"}
    batch_position = {batch["id"]: i for i, batch in enumerate(batches)}
    for batch in batches:
        assert all(batch_position[dependency] < batch_position[batch["id"]] for dependency in batch["depends_on"])
    location = {entry["source"]: batch["id"] for batch in batches for entry in batch["entries"]}
    for original, row in localized.items():
        if original in pending and row["path"] in pending:
            assert location[original] == location[row["path"]], original
    for name in GROUND_PILOT:
        assert location[f"Graphics/Battlebacks/enemybase/{name}.png"] == location[f"Graphics/Battlebacks/playerbase/{name}.png"]
    assert batches[0]["id"] == "batch-005" and batches[0]["file_count"] == 12
    priorities = []
    for priority in ("P1", "P2", "P3", "P4", "P5"):
        selected = [b for b in batches if b["priority"] == priority]
        priorities.append({"priority": priority, "files": sum(b["file_count"] for b in selected),
                           "batches": len(selected), "first": selected[0]["id"], "last": selected[-1]["id"]})
    stages = [{"stage": key, "priority": priority, "title": title, "method": method,
               "files": sum(b["file_count"] for b in batches if b["stage"] == key),
               "batch_ids": stage_ids[key]} for key, priority, title, method, _, _ in STAGES if stage_ids[key]]
    plan = {"version": 1, "created_date": "2026-10-27", "timezone": "Asia/Shanghai", "status": "planned_only",
            "inventory_sha256": hashlib.sha256(inventory_bytes).hexdigest(), "total_images": inventory["total"],
            "already_applied_images": inventory["applied"], "remaining_images": len(pending),
            "batch_count": len(batches), "next_batch": "batch-005", "priorities": priorities,
            "priority_basis": "按可见收益、与已完成素材的配套关系和结构风险排序；未宣称完成运行频次统计。",
            "stages": stages, "methods": METHODS,
            "batch_index": [{k: v for k, v in b.items() if k != "entries"} for b in batches]}
    DEST.mkdir(exist_ok=True)
    (DEST / "batches").mkdir(exist_ok=True)
    for batch in batches:
        (DEST / "batches" / (batch["id"] + ".json")).write_text(json.dumps(batch, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (DEST / "plan.json").write_text(json.dumps(plan, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    report = {"result": "PASS", "pending_files": len(pending), "assigned_files": len(assigned), "duplicates": 0,
              "omissions": 0, "batches": len(batches), "completed_images_excluded": inventory["applied"],
              "chinese_pairs_kept_together": len(localized), "dependencies_point_backward": True,
              "game_images_modified": False, "image_generation_started": False, "priorities": priorities}
    (DEST / "validation.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    index = ["# 全部执行批次索引", "", "本索引的文件数量含配套中文图；批次编号固定，完成后不重新排序。", "",
             "| 批次 | 优先级 | 内容 | 文件数 | 状态 |", "| --- | --- | --- | ---: | --- |"]
    for batch in batches:
        status = "先核查用途" if batch["method"] == "audit" else "待执行"
        index.append(f"| [{batch['number']}](batches/{batch['id']}.json) | {batch['priority']} | {batch['title']} | {batch['file_count']} | {status} |")
    (DEST / "batch-index.zh-CN.md").write_text("\n".join(index) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
