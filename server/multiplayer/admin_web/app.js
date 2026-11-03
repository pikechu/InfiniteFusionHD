"use strict";
// Credentials live only in memory. Every dynamic value is rendered as text.
const $ = (id) => document.getElementById(id);
const state = {token: null, admin: null, page: "overview", player: null, query: "", filter: "all", cursor: null, pending: null, busy: false, currency: "GOLD", period: "today", start: "", end: "", pricePeriod: "30d", priceStart: "", priceEnd: "", priceSpecies: "", priceMinLevel: 1, priceMaxLevel: 100, priceShiny: "any", priceMinIV: 0, transactionKind: "shop", renderSequence: 0, dataVersion: 0, renderedView: null, exportPending: false};
const titles = {overview: "全服总览", players: "玩家管理", economy: "经济与账本", prices: "市场价格分析", transactions: "商城与交易记录", commerce: "商城与市场运营", controlled: "受控库存复核", batches: "批量活动发放", retention: "活跃与留存", alerts: "风险调查", exports: "报表导出", audit: "操作审计", detail: "玩家详情"};
function el(tag, text, cls) { const node = document.createElement(tag); if (text !== undefined && text !== null) node.textContent = String(text); if (cls) node.className = cls; return node; }
function time(value) { return value ? new Date(value * 1000).toLocaleString("zh-CN", {timeZone: "Asia/Shanghai", hour12: false}) : "—"; }
function number(value) { return value === null || value === undefined ? "未采集" : Number(value).toLocaleString("zh-CN"); }
let messageTimer;
function message(text, error = false) { clearTimeout(messageTimer); $("message").textContent = text; $("message").className = error ? "error" : ""; $("message").hidden = false; if (!error) messageTimer = setTimeout(() => {$("message").hidden = true;}, 8000); }
function button(text, action, cls) { const node = el("button", text, cls); node.type = "button"; node.addEventListener("click", action); return node; }
function reset() { state.token = null; state.admin = null; state.pending = null; state.busy = false; state.renderSequence++; state.dataVersion++; state.renderedView = null; $("workspace").hidden = true; $("login-panel").hidden = false; $("content").replaceChildren(); $("password").value = ""; $("otp").value = ""; clearTimeout(messageTimer); $("message").hidden = true; $("message").textContent = ""; $("confirmation").close(); }
async function api(path, body) {
  const token = state.token, controller = new AbortController(), timer = setTimeout(() => controller.abort(), 15000);
  try {
    const response = await fetch("/admin/v1/" + path, {method: body === undefined ? "GET" : "POST", cache: "no-store", credentials: "omit", signal: controller.signal, headers: {"Content-Type": "application/json", ...(token ? {Authorization: "Bearer " + token} : {})}, ...(body === undefined ? {} : {body: JSON.stringify(body)})});
    const data = await response.json();
    if (!response.ok || data?.ok !== true) {if (response.status === 401 && token && state.token === token) reset(); const error = new Error(data?.error?.message || "请求失败"); error.status = response.status; throw error;}
    return data;
  } catch (error) {if (error.name === "AbortError") throw new Error("请求超时；已提交的操作请使用原指令编号确认结果。"); throw error;}
  finally {clearTimeout(timer);}
}
function panel(title) { const node = el("section", null, "panel"); if (title) node.append(el("h2", title)); $("content").append(node); return node; }
function table(parent, headers, rows) {
  const wrap = el("div", null, "table-wrap"), grid = el("table"), head = el("thead"), hr = el("tr");
  if (headers.length >= 4) grid.className = "table-wide";
  headers.forEach((title) => hr.append(el("th", title))); head.append(hr); grid.append(head);
  const body = el("tbody");
  rows.forEach((cells) => {const row = el("tr"); cells.forEach((value) => {const cell = el("td"); if (typeof value === "number" || typeof value === "string" && /^-?[0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?$/.test(value)) cell.className = "numeric"; if (typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value)) cell.className = "date-value"; cell.append(value instanceof Node ? value : document.createTextNode(String(value ?? "—"))); row.append(cell);}); body.append(row);});
  grid.append(body); wrap.append(grid); parent.append(wrap); if (!rows.length) parent.append(el("p", "暂无记录", "empty"));
}
function details(parent, values) { const list = el("dl", null, "details"); values.forEach(([key, value]) => { const item = el("div"); item.append(el("dt", key), el("dd", value)); list.append(item); }); parent.append(list); }
function badge(text, severity = "") { return el("span", text, "badge " + severity); }
function currentView() {return {page: state.page, player: state.player, currency: state.currency, priceCurrency: state.priceCurrency || "MARKET", period: state.period, start: state.start, end: state.end, pricePeriod: state.pricePeriod, priceStart: state.priceStart, priceEnd: state.priceEnd, priceSpecies: state.priceSpecies, priceMinLevel: state.priceMinLevel, priceMaxLevel: state.priceMaxLevel, priceShiny: state.priceShiny, priceMinIV: state.priceMinIV, cursor: state.cursor, query: state.query, filter: state.filter, transactionKind: state.transactionKind};}
function periodFilter(view = state) {return view.period === "custom" ? {start: view.start, end: view.end} : {period: view.period};}
function priceFilter(view = state) {return {...(view.pricePeriod === "custom" ? {start: view.priceStart, end: view.priceEnd} : {period: view.pricePeriod}), currency: view.priceCurrency || "MARKET", species: view.priceSpecies, min_level: view.priceMinLevel, max_level: view.priceMaxLevel, shiny: view.priceShiny, min_iv: view.priceMinIV};}
async function render() {
  if (!state.token || state.busy) return;
  const view = currentView(), key = JSON.stringify(view), token = state.token, version = state.dataVersion, sequence = ++state.renderSequence;
  state.busy = true; $("refresh").disabled = true;
  try {
    $("page-title").textContent = titles[view.page];
    document.querySelectorAll(".nav-button").forEach((node) => node.classList.toggle("active", node.dataset.page === view.page || view.page === "detail" && node.dataset.page === "players"));
    let data;
    if (view.page === "overview") data = await api("overview");
    if (view.page === "players") data = await api("players?" + new URLSearchParams({q: view.query, state: view.filter, ...(view.cursor ? {after: view.cursor} : {})}));
    if (view.page === "detail") data = await api("players/" + encodeURIComponent(view.player));
    if (view.page === "audit") data = await api("audit" + (view.cursor ? "?before=" + view.cursor : ""));
    if (view.page === "economy") {const filters = new URLSearchParams({currency: view.currency, ...periodFilter(view)}); const [report, ledger] = await Promise.all([api("economy?" + filters), api("ledger?" + filters + (view.cursor ? "&before=" + view.cursor : ""))]); data = {report, ledger};}
    if (view.page === "transactions") data = await api("transactions?kind=" + view.transactionKind + (view.cursor ? "&before=" + view.cursor : ""));
    if (view.page === "prices") data = await api("market-prices?" + new URLSearchParams(priceFilter(view)));
    if (["retention", "alerts", "exports", "batches", "commerce"].includes(view.page)) data = await api(view.page);
    if (view.page === "controlled") data = await api("controlled-proposals");
    if (sequence !== state.renderSequence || token !== state.token || version !== state.dataVersion || key !== JSON.stringify(currentView())) return;
    $("content").replaceChildren();
    if (state.page === "overview") overview(data);
    if (state.page === "players") players(data);
    if (state.page === "detail") playerDetail(data);
    if (state.page === "audit") audit(data.entries);
    if (state.page === "economy") economy(data);
    if (state.page === "transactions") transactions(data);
    if (state.page === "prices") marketPrices(data);
    if (state.page === "retention") retention(data);
    if (state.page === "alerts") alerts(data);
    if (state.page === "exports") exportsPage(data);
    if (state.page === "batches") batchesPage(data);
    if (state.page === "commerce") commercePage(data);
    if (state.page === "controlled") controlledProposals(data);
    if (state.renderedView !== key) {window.scrollTo(0, 0); state.renderedView = key;}
  } catch (error) {if (sequence === state.renderSequence && token === state.token && version === state.dataVersion && key === JSON.stringify(currentView())) message(error.message, true);}
  finally {if (sequence === state.renderSequence) {state.busy = false; $("refresh").disabled = false; if (state.token && (token !== state.token || version !== state.dataVersion || key !== JSON.stringify(currentView()))) render();}}
}
function overview(data) {
  $("content").append(el("p", "Asia/Shanghai · 截至 " + time(data.as_of) + " · 活动采集开始于 " + time(data.collection_started), "muted small"));
  const cards = el("div", null, "cards");
  [["当前世界在线", data.online, "20 秒内有效游戏心跳"], ["今日活跃账号", data.dau, "服务端账号去重"], ["注册账号", data.accounts, "今日新增 " + number(data.new_accounts)], ["今日在线峰值", data.peak_online, "按已采集心跳记录"], ["近 7 天活跃", data.wau, "不同账号去重"], ["近 30 天活跃", data.mau, "不同账号去重"], ["封禁账号", data.banned, "禁言 " + number(data.muted)], ["云存档槽位", data.cloud_slots, "已提取摘要 " + number(data.summarized_slots)], ["受控角色 GOLD 总量", data.controlled_gold, "含冻结与封禁持有"], ["今日 GOLD 产出", data.controlled_gold_issued_today, "服务端发行流水"], ["今日 GOLD 回收", data.controlled_gold_retired_today, "服务端销毁流水"], ["受控角色数量", data.controlled_characters, "历史存档资产不导入"]].forEach(([label, value, hint]) => {const node = el("div", null, "metric"); node.append(el("div", label, "label"), el("div", number(value), "value"), el("div", hint, "hint")); cards.append(node);});
  $("content").append(cards, el("p", "旧主线金币按存档快照和角色归并口径查看；新建受控角色的 GOLD 使用独立的服务端账本，详情见“经济与账本”。", "notice"));
  const gold = data.mainline_gold;
  if (gold.registered_characters) details(panel("已归并角色的主线金币快照"), [["已采集快照金额", number(gold.value)], ["已覆盖角色 / 已归并角色", gold.covered_characters + " / " + gold.registered_characters], ["尚未归并的槽位", gold.unresolved_slots], ["数据来源", "客户端存档快照 · 未核验"]]);
  table(panel("最近 30 天账号活跃"), ["日期", "活跃账号", "观察到的在线时长"], data.activity.map((row) => [row.day, number(row.active_accounts), Math.round(row.observed_seconds / 60) + " 分钟"]));
}
function players(data) {
  const box = panel(), form = el("form", null, "toolbar"), input = el("input"), select = el("select");
  input.placeholder = "账号 / 昵称 / 好友码 / 玩家 ID"; input.setAttribute("aria-label", "搜索玩家"); input.value = state.query;
  [["all", "全部状态"], ["online", "在线"], ["banned", "封禁中"], ["muted", "禁言中"]].forEach(([value, text]) => {const item = el("option", text); item.value = value; select.append(item);}); select.value = state.filter; select.setAttribute("aria-label", "玩家状态");
  const submit = el("button", "查询", "primary"); submit.type = "submit"; form.append(input, select, submit);
  form.addEventListener("submit", (event) => {event.preventDefault(); state.query = input.value; state.filter = select.value; state.cursor = null; render();}); box.append(form);
  table(box, ["玩家", "账号", "好友码", "状态", "注册时间", "操作"], data.players.map((row) => {
    const tags = el("div"); if (row.ban_until > data.as_of) tags.append(badge("封禁", "error")); if (row.mute_until > data.as_of) tags.append(badge("禁言", "warning")); if (row.online) tags.append(badge("在线")); if (!tags.children.length) tags.append(badge("离线", "warning"));
    const name = el("div", row.nickname); name.append(el("div", row.id, "muted small"));
    return [name, row.username || "历史临时身份", row.friend_code, tags, time(row.created), button("查看详情", () => {state.player = row.id; state.page = "detail"; render();}, "link")];
  }));
  const actions = el("div", null, "actions"); if (state.cursor) actions.append(button("返回第一页", () => {state.cursor = null; render();})); if (data.next_cursor) actions.append(button("下一页", () => {state.cursor = data.next_cursor; render();})); box.append(actions);
}
function playerDetail(data) {
  const p = data.player, c = data.controls;
  const top = panel(p.nickname + " · " + (p.username || "历史临时身份")); top.prepend(button("← 返回玩家列表", () => {state.page = "players"; render();}, "link"));
  if (state.admin.permissions.includes("export")) top.append(button("导出当前玩家资料", () => startExport("players", p.id)));
  details(top, [["玩家 ID", p.id], ["好友码", p.friend_code], ["注册时间", time(p.created)], ["当前在线", data.presence ? "在线 · " + time(data.presence.heartbeat_at) : "离线"], ["封禁截止", c.ban_until > data.as_of ? time(c.ban_until) : "未封禁"], ["禁言截止", c.mute_until > data.as_of ? time(c.mute_until) : "未禁言"], ["交易状态", c.trade_frozen ? "已冻结" : "正常"], ["管理状态版本", c.version]]);
  const saves = panel("存档摘要"); saves.append(el("p", "以下为客户端上传快照，不代表服务端核实的资产。历史角色尚未归并，槽位余额不相加。", "notice"));
  table(saves, ["槽位 / 版本", "训练师", "金币快照", "队伍 / 徽章", "状态", "上传时间", "历史"], data.saves.map((save) => [save.slot + " / " + save.revision, save.summary.trainer_name, number(save.summary.money), number(save.summary.party_count) + " / " + number(save.summary.badges), {ready: "已提取 · 未核验", pending: "等待提取", invalid: "格式错误 / 不支持"}[save.summary.status] || save.summary.status, time(save.uploaded_at), button("历史版本", async () => {try {const history = await api("save-history?" + new URLSearchParams({owner: p.id, slot: save.slot})); const box = panel(save.slot + " · 历史快照"); table(box, ["版本", "上传时间", "修复前保留", "校验和"], history.versions.map((item) => [item.revision, time(item.updated), item.pinned ? "是" : "否", item.sha256])); box.scrollIntoView({behavior: "smooth"});} catch (error) {message(error.message, true);}}, "link")]));
  if (data.maintenance) saves.append(el("p", "账号处于维护状态：" + data.maintenance.id + "。修复完成后需结束维护，玩家才能重新登录。", "notice"));
  if (state.admin.permissions.includes("economy")) {saveTools(data); rollbackTools(data); originalRollbackTools(data);}
  const hosted = panel("服务器托管精灵（最多显示 100 条）"), inspector = el("div");
  table(hosted, ["资产 ID", "物种", "等级", "来源", "锁记录", "个体资料"], data.hosted_assets.map((asset) => [asset.id, JSON.stringify(asset.species), asset.level, asset.source, asset.locked ? "有" : "无", button("查看个体", async () => {try {const detail = await api("assets/" + asset.id); inspector.replaceChildren(el("h3", asset.id), el("pre", JSON.stringify(detail, null, 2)));} catch (error) {message(error.message, true);}}, "link")])); hosted.append(inspector);
  const financialWallets = [...data.wallets, ...(data.controlled_characters || []).map((character) => ({...character.wallet, character_id: character.id, character_name: character.name}))];
  const walletKey = (wallet) => wallet.currency + (wallet.character_id ? ":" + wallet.character_id : "");
  const wallets = panel("服务端钱包");
  table(wallets, ["币种 / 角色", "余额", "版本", "来源"], financialWallets.map((wallet) => [wallet.currency === "MARKET" ? "联机币 MARKET" : wallet.currency === "RP" ? "商城点券 RP" : "受控金币 GOLD / " + wallet.character_name, number(wallet.balance), wallet.revision, "服务端账本"]));
  if ((data.controlled_characters || []).length) controlledInventory(data);
  if ((data.controlled_characters || []).length) {
    const adventure = panel("受控主线与精灵"), inspector = el("div"), toolbar = el("div", null, "toolbar");
    data.controlled_characters.forEach((character) => toolbar.append(button("查询 " + character.name, async () => {try {const result = await api("controlled-character?" + new URLSearchParams({id: character.id})); if (!inspector.isConnected) return; inspector.replaceChildren(); if (result.original?.active) {originalInspector(inspector, result); return;} details(inspector, [["角色", character.name], ["已完成章节", result.adventure.progress.chapter], ["等级上限", result.adventure.level_cap], ["当前战斗", result.adventure.battle ? result.adventure.battle.id + " / 回合 " + result.adventure.battle.round + " / 截止 " + time(result.adventure.battle.expires) : "无"]]); table(inspector, ["编号 / 物种", "等级", "HP / 状态", "类型", "版本"], result.adventure.monsters.map((monster) => [monster.id + " / " + monster.name, monster.level, monster.hp + " / " + monster.stats.HP + " · " + monster.status, monster.egg ? "待孵化 · " + time(monster.hatch_at) : monster.components ? "融合" : "基础", monster.revision])); table(inspector, ["时间", "精灵", "操作", "关联编号"], result.events.map((entry) => [time(entry.created), entry.monster_id, entry.kind, entry.reference]));} catch (error) {message(error.message, true);}})));
    adventure.append(toolbar, inspector);
  }
  if (state.admin.permissions.includes("economy")) {
    const form = el("form", null, "control-form"), currency = el("select"), amount = el("input"), reason = el("textarea");
    financialWallets.forEach((wallet) => {const option = el("option", wallet.currency + (wallet.character_name ? " / " + wallet.character_name : "")); option.value = walletKey(wallet); currency.append(option);});
    amount.type = "number"; amount.required = true; amount.min = "-1000000000"; amount.max = "1000000000"; amount.step = "1";
    reason.required = true; reason.minLength = 3; reason.maxLength = 500;
    [["币种", currency, ""], ["增减数量（扣回填负数）", amount, ""], ["补偿 / 扣回原因", reason, "wide"]].forEach(([label, input, cls]) => {const node = el("label", label, cls); node.append(input); form.append(node);});
    const submit = el("button", "预览钱包调整", "primary"); submit.type = "submit"; form.append(submit); wallets.append(el("p", "单笔绝对值超过 10,000，或当日累计超过 100,000 的调整，需要另一名有经济权限的管理员复核。", "muted small"), form);
    form.addEventListener("submit", (event) => {event.preventDefault(); const wallet = financialWallets.find((item) => walletKey(item) === currency.value); const value = Number(amount.value); if (!Number.isSafeInteger(value) || value === 0) {message("请输入非零整数", true); return;} preview({id: crypto.randomUUID(), action: "adjust_wallet", target: p.id, reason: reason.value, expected_version: c.version, currency: wallet.currency, ...(wallet.character_id ? {character_id: wallet.character_id} : {}), amount: value, expected_wallet_revision: wallet.revision}, [["目标", p.nickname + (wallet.character_name ? " / " + wallet.character_name : "")], ["币种", wallet.currency], ["余额变化", number(wallet.balance) + " → " + number(wallet.balance + value)], ["原因", reason.value]]);});
  }
  if (state.admin.permissions.includes("moderate")) {
    const box = panel("玩家管理操作"), form = el("form", null, "control-form"), action = el("select"), duration = el("select"), reason = el("textarea");
    [["note", "添加备注"], ["kick", "踢下线"], ["mute", "禁言"], ["unmute", "解除禁言"], ["ban", "封禁账号"], ["unban", "解除封禁"], ["freeze_trade", "冻结经济操作"], ["unfreeze_trade", "解除经济冻结"]].forEach(([value, text]) => {const node = el("option", text); node.value = value; action.append(node);});
    const maintenanceOption = el("option", data.maintenance ? "结束存档维护" : "开始存档维护"); maintenanceOption.value = data.maintenance ? "end_maintenance" : "begin_maintenance"; action.append(maintenanceOption);
    [["3600", "1 小时"], ["86400", "1 天"], ["604800", "7 天"], ["2592000", "30 天"], ["0", "长期"]].forEach(([value, text]) => {const node = el("option", text); node.value = value; duration.append(node);});
    duration.value = "86400"; reason.required = true; reason.minLength = 3; reason.maxLength = 500; reason.placeholder = "填写操作原因或关联工单编号";
    const la = el("label", "操作类型"), ld = el("label", "封禁 / 禁言期限"), lr = el("label", "操作原因", "wide"); la.append(action); ld.append(duration); lr.append(reason); const submit = el("button", "预览操作", "primary"); submit.type = "submit";
    const force = el("input"); force.type = "checkbox"; const lf = el("label", "开始维护时强制撤销仍有效的写入会话（未上传进度可能需要人工恢复）", "wide"); lf.append(force);
    form.append(la, ld, lr, lf, submit); box.append(form);
    form.addEventListener("submit", (event) => {event.preventDefault(); const command = {id: crypto.randomUUID(), action: action.value, target: p.id, reason: reason.value, expected_version: c.version}; if (["ban", "mute"].includes(action.value)) command.duration_seconds = Number(duration.value); if (action.value === "begin_maintenance") command.force = force.checked; if (action.value === "end_maintenance") command.maintenance_id = data.maintenance.id; preview(command, [["目标玩家", p.nickname + " / " + p.id], ["操作", action.selectedOptions[0].textContent], ["原因", reason.value], ["当前版本", c.version], ...(action.value === "begin_maintenance" ? [["强制撤销写入", force.checked ? "是" : "否"]] : [])]);});
  }
  audit(data.history, false);
}
function audit(entries, full = true) {
  const box = panel("操作记录");
  table(box, ["编号 / 时间", "操作者", "动作 / 目标", "原因", "变更详情"], entries.map((entry) => {const detail = el("details"), summary = el("summary", "展开"); detail.append(summary, el("pre", JSON.stringify(entry.detail, null, 2))); return [entry.id + " · " + time(entry.created), entry.actor, entry.action + (entry.target ? " / " + entry.target : ""), entry.reason || "—", detail];}));
  if (full && entries.length) {const actions = el("div", null, "actions"); actions.append(button("更早记录", () => {state.cursor = entries[entries.length - 1].id; render();})); if (state.cursor) actions.append(button("最新记录", () => {state.cursor = null; render();})); box.append(actions);}
}
function preview(command, values) {state.pending = command; $("command-preview").replaceChildren(); details($("command-preview"), [...values, ["指令 ID", command.id]]); $("confirmation").showModal();}
function originalInspector(inspector, result) {
  const original = result.original, view = original.view, world = view.world || {}, trainer = view.trainer || {};
  details(inspector, [["角色", result.character.name], ["规则", "原版 · " + original.rules_hash], ["地图", (world.name || "") + " / " + world.map_id], ["位置", world.x + ", " + world.y], ["徽章", (trainer.badges || []).filter(Boolean).length], ["交互", original.prompt ? original.prompt.kind : "空闲"], ["角色版本", result.character.revision]]);
  table(inspector, ["编号 / 物种", "等级 / 经验", "HP / 状态", "特性 / 携带物", "个体值 / 努力值"], view.monsters.map((monster) => [monster.id + " / " + monster.name, monster.level + " / " + monster.exp, monster.hp + " / " + monster.max_hp + " · " + monster.status, monster.ability + " / " + (monster.item || "无"), JSON.stringify(monster.iv) + " / " + JSON.stringify(monster.ev)]));
  table(inspector, ["时间", "操作", "关联编号", "金币变化"], result.events.map((entry) => [time(entry.created), entry.kind, entry.request_id, entry.detail.money_delta || 0]));
}
function originalRollbackTools(data) {
  const characters = data.controlled_characters.filter((row) => row.rules_mode === "original");
  if (!characters.length) return;
  const box = panel("原版受控角色整档回滚"), role = el("select"), checkpoint = el("select"), reason = el("textarea"), form = el("form", null, "control-form");
  box.append(el("p", "恢复服务器检查点的剧情、地图、培养和背包；已转出的精灵及关联融合/拆分资产保持归属。外部交易金币保留，通过补偿账本恢复余额。服务器检查资产冲突，另一名管理员复核完整影响后执行。", "notice"));
  const reviews = el("div"); box.append(reviews);
  const loadReviews = button("读取角色回滚申请", async () => {try {const result = await api("original-rollbacks?" + new URLSearchParams({target: data.player.id})); if (!reviews.isConnected) return; reviews.replaceChildren(); table(reviews, ["申请 / 角色", "申请人", "影响预览", "状态", "操作"], result.proposals.map((proposal) => {const instruction = proposal.detail.instruction, detail = el("details"); detail.append(el("summary", "查看回滚前后及资产保留清单"), el("pre", JSON.stringify(proposal.detail.preview, null, 2))); const actions = el("div", null, "toolbar"); if (proposal.status === "pending" && proposal.expires > result.as_of) {if (proposal.actor !== state.admin.username) actions.append(button("独立复核并回滚", () => preview({id: crypto.randomUUID(), action: "approve_original_rollback", reason: "复核原版角色回滚：" + instruction.reason, proposal_id: proposal.id}, [["申请人", proposal.actor], ["角色", instruction.character_id], ["检查点", instruction.restore_revision], ["金币", proposal.detail.preview.money_before + " → " + proposal.detail.preview.money_after], ["保留资产", proposal.detail.preview.protected_ids.join("、") || "无外部转移"], ["依据", instruction.reason]]), "danger")); if (proposal.actor === state.admin.username || state.admin.role === "admin") actions.append(button("取消申请", () => preview({id: crypto.randomUUID(), action: "cancel_original_rollback", reason: "取消原版角色回滚：" + instruction.reason, proposal_id: proposal.id}, [["申请", proposal.id], ["操作", "取消回滚"]])));} return [proposal.id + " / " + instruction.character_id, proposal.actor, detail, proposal.status, actions];}));} catch (error) {message(error.message, true);}});
  box.append(loadReviews);
  if (!data.maintenance) {box.append(el("p", "开始账号维护后可创建整档回滚申请。", "muted")); return;}
  characters.forEach((character) => {const option = el("option", character.name + " / " + character.id); option.value = character.id; role.append(option);});
  reason.required = true; reason.minLength = 3; reason.maxLength = 450;
  [["原版角色", role], ["恢复检查点", checkpoint], ["回滚依据", reason]].forEach(([label, input]) => {const field = el("label", label); field.append(input); form.append(field);});
  let current = null, loadSequence = 0;
  const submit = el("button", "创建回滚影响预览申请", "primary"); submit.type = "submit"; submit.disabled = true; form.append(submit); box.append(form);
  async function load() {const sequence = ++loadSequence; submit.disabled = true; checkpoint.replaceChildren(); try {const [history, detail] = await Promise.all([api("original-checkpoints?" + new URLSearchParams({id: role.value})), api("controlled-character?" + new URLSearchParams({id: role.value}))]); if (!form.isConnected || sequence !== loadSequence) return; current = detail.character; history.checkpoints.filter((row) => row.revision < current.revision).forEach((row) => {const option = el("option", "版本 " + row.revision + " / " + time(row.created) + " / " + row.summary.name + " / GOLD " + row.wallet_balance); option.value = String(row.revision); checkpoint.append(option);}); submit.disabled = checkpoint.options.length === 0;} catch (error) {message(error.message, true);}}
  role.addEventListener("change", load); load();
  form.addEventListener("submit", (event) => {event.preventDefault(); if (!current) return; preview({id: crypto.randomUUID(), action: "request_original_rollback", target: data.player.id, reason: reason.value, expected_version: data.controls.version, maintenance_id: data.maintenance.id, character_id: role.value, expected_revision: current.revision, restore_revision: Number(checkpoint.value)}, [["角色", current.name], ["当前角色版本", current.revision], ["恢复来源", checkpoint.value], ["后续步骤", "服务端生成完整影响预览，另一名管理员复核"], ["依据", reason.value]]);});
}
function controlledInventory(data) {
  const box = panel("受控在线角色与背包"); box.append(el("p", "以下为新建受控角色的服务端资产，与旧存档快照分开。库存调整需另一名管理员复核。", "notice"));
  table(box, ["角色 / 编号", "GOLD", "库存", "角色版本"], data.controlled_characters.map((character) => [character.name + " / " + character.id, number(character.wallet.balance), character.inventory.map((item) => item.item + " × " + item.quantity).join("、") || "空", character.revision]));
  if (!state.admin.permissions.includes("economy")) return;
  const form = el("form", null, "control-form"), character = el("select"), item = el("select"), amount = el("input"), reason = el("textarea");
  data.controlled_characters.forEach((entry) => {const option = el("option", entry.name + " / " + entry.id); option.value = entry.id; character.append(option);});
  amount.type = "number"; amount.min = "-999"; amount.max = "999"; amount.step = "1"; amount.required = true; reason.required = true; reason.minLength = 3; reason.maxLength = 500;
  [["受控角色", character, ""], ["道具", item, ""], ["增减数量", amount, ""], ["调整依据", reason, "wide"]].forEach(([label, input, cls]) => {const node = el("label", label, cls); node.append(input); form.append(node);}); const submit = el("button", "预览库存调整申请", "primary"); submit.type = "submit"; form.append(submit); box.append(form);
  let selectionVersion = 0;
  async function loadItems() {
    const version = ++selectionVersion, selected = character.value;
    submit.disabled = true; item.replaceChildren();
    try {
      const result = await api("controlled-character?" + new URLSearchParams({id: selected}));
      if (version !== selectionVersion || !form.isConnected) return;
      const entries = result.original?.active ? result.item_catalog : data.controlled_catalog.items;
      entries.forEach((entry) => {const option = el("option", entry.name + " / " + entry.id); option.value = entry.id; item.append(option);});
      Object.assign(data.controlled_characters.find((entry) => entry.id === selected), result.character);
      submit.disabled = entries.length === 0;
    } catch (error) {if (version === selectionVersion && form.isConnected) message(error.message, true);}
  }
  character.addEventListener("change", loadItems); loadItems();
  form.addEventListener("submit", (event) => {event.preventDefault(); const selected = data.controlled_characters.find((entry) => entry.id === character.value), value = Number(amount.value), before = selected.inventory.find((entry) => entry.item === item.value)?.quantity || 0; if (!Number.isInteger(value) || value === 0) {message("请输入非零整数", true); return;} preview({id: crypto.randomUUID(), action: "adjust_inventory", target: data.player.id, reason: reason.value, expected_version: data.controls.version, character_id: selected.id, expected_revision: selected.revision, item: item.value, amount: value}, [["角色", selected.name], ["道具", item.value], ["库存变化", before + " → " + (before + value)], ["原因", reason.value]]);});
}
function controlledProposals(data) {
  const box = panel("受控库存调整申请"); box.append(el("p", "申请执行前会重新核对玩家管理状态、角色版本和当前库存。", "notice"));
  table(box, ["申请编号", "申请人", "账号 / 角色", "道具 / 数量", "原因", "状态", "操作"], data.proposals.map((proposal) => {const d = proposal.detail, canApprove = proposal.status === "pending" && proposal.expires > data.as_of && proposal.actor !== state.admin.username; return [proposal.id, proposal.actor, d.target + " / " + d.character_id, d.item + " / " + d.amount, d.reason, proposal.status === "pending" && proposal.expires <= data.as_of ? "已过期" : proposal.status, canApprove ? button("复核并执行", () => preview({id: crypto.randomUUID(), action: "approve_inventory", reason: ("复核 " + proposal.id + "：" + d.reason).slice(0, 500), proposal_id: proposal.id}, [["申请人", proposal.actor], ["角色", d.character_id], ["道具 / 增减量", d.item + " / " + d.amount], ["原因", d.reason]]), "link") : "—"]; }));
}
function saveTools(data) {
  const p = data.player, c = data.controls;
  const groups = panel("角色与存档关联");
  table(groups, ["角色 ID", "当前统计槽位", "关联槽位"], data.characters.map((item) => [item.id, item.canonical_slot, item.slots.join("、")]));
  const associated = new Set(data.characters.flatMap((item) => item.slots)), available = data.saves.filter((item) => !associated.has(item.slot));
  if (available.length) {
    groups.append(el("p", "人工核对后，选择属于同一个角色的存档。总览仅统计该角色选定槽位的一份快照；这项关联不会验证金币来源。", "muted small"));
    const form = el("form", null, "control-form"), chosen = [], canonical = el("select"), reason = el("textarea");
    available.forEach((save) => {const box = el("input"); box.type = "checkbox"; box.value = save.slot; chosen.push(box); const label = el("label", save.slot + " / " + (save.summary.trainer_name || "未知训练师") + " / " + number(save.summary.money)); label.append(box); form.append(label); const option = el("option", save.slot); option.value = save.slot; canonical.append(option);});
    const lc = el("label", "用于统计的当前槽位"), lr = el("label", "归并依据", "wide"); lc.append(canonical); reason.required = true; reason.minLength = 3; reason.maxLength = 500; lr.append(reason); const submit = el("button", "预览角色归并", "primary"); submit.type = "submit"; form.append(lc, lr, submit); groups.append(form);
    form.addEventListener("submit", (event) => {event.preventDefault(); const slots = chosen.filter((item) => item.checked).map((item) => item.value); if (!slots.length || !slots.includes(canonical.value)) {message("请选择槽位，并把当前统计槽位包含在选择中", true); return;} preview({id: crypto.randomUUID(), action: "group_character", target: p.id, reason: reason.value, expected_version: c.version, slots, canonical_slot: canonical.value}, [["玩家", p.nickname], ["同一角色的槽位", slots.join("、")], ["当前统计槽位", canonical.value], ["归并依据", reason.value]]);});
  }
  if (data.maintenance && data.saves.length) {
    const box = panel("修复主线金币快照"), form = el("form", null, "control-form"), slot = el("select"), amount = el("input"), reason = el("textarea");
    data.saves.forEach((save) => {const option = el("option", save.slot + " / 版本 " + save.revision); option.value = save.slot; slot.append(option);});
    amount.type = "number"; amount.min = "0"; amount.max = "999999"; amount.step = "1"; amount.required = true; reason.required = true; reason.minLength = 3; reason.maxLength = 500;
    [["目标槽位", slot, ""], ["修复后的金币（0～999,999）", amount, ""], ["修复依据", reason, "wide"]].forEach(([label, input, cls]) => {const node = el("label", label, cls); node.append(input); form.append(node);});
    const submit = el("button", "预览存档修复", "primary"); submit.type = "submit"; form.append(submit); box.append(el("p", "修复前版本会单独保留，成功后云档版本递增。这项操作不调整联机币、点券、托管资产或订单。", "notice"), form);
    form.addEventListener("submit", (event) => {event.preventDefault(); const selected = data.saves.find((save) => save.slot === slot.value); preview({id: crypto.randomUUID(), action: "repair_save_money", target: p.id, reason: reason.value, expected_version: c.version, maintenance_id: data.maintenance.id, slot: slot.value, expected_revision: selected.revision, money: Number(amount.value)}, [["玩家 / 槽位", p.nickname + " / " + slot.value], ["当前版本", selected.revision], ["金币快照变化", number(selected.summary.money) + " → " + number(Number(amount.value))], ["修复依据", reason.value]]);});
  }
}
function rollbackTools(data) {
  const box = panel("整档回滚 · 独立复核"), owner = data.player.id;
  box.append(el("p", "恢复选定槽位的完整历史云档，并创建新的云档版本。受控角色、金币、背包、精灵、商城与交易保持当前状态；回滚前版本与来源版本均会保留。需先进入存档维护。", "notice"));
  if (data.maintenance && data.saves.length) {
    const form = el("form", null, "control-form"), slot = el("select"), version = el("select"), reason = el("textarea");
    let history = [];
    data.saves.forEach((save) => {const option = el("option", save.slot + " / 当前版本 " + save.revision); option.value = save.slot; slot.append(option);});
    version.disabled = true; reason.required = true; reason.minLength = 3; reason.maxLength = 500;
    slot.addEventListener("change", () => {history = []; version.replaceChildren(); version.disabled = true;});
    [["目标槽位", slot, ""], ["恢复到的历史版本", version, ""], ["整档回滚依据", reason, "wide"]].forEach(([text, input, cls]) => {const label = el("label", text, cls); label.append(input); form.append(label);});
    const load = button("读取可回滚版本", async () => {load.disabled = true; try {const selected = slot.value, result = await api("save-history?" + new URLSearchParams({owner, slot: selected})); if (!form.isConnected || slot.value !== selected) return; history = result.versions; version.replaceChildren(); const current = data.saves.find((save) => save.slot === selected); history.filter((item) => item.revision < current.revision).forEach((item) => {const option = el("option", "版本 " + item.revision + " / " + time(item.updated)); option.value = String(item.revision); version.append(option);}); version.disabled = !version.options.length; if (version.disabled) message("没有比当前版本更早的可用快照", true);} catch (error) {message(error.message, true);} finally {load.disabled = false;}});
    const submit = el("button", "预览整档回滚申请", "primary"); submit.type = "submit"; form.append(load, submit); box.append(form);
    form.addEventListener("submit", (event) => {event.preventDefault(); const current = data.saves.find((save) => save.slot === slot.value), source = history.find((item) => item.revision === Number(version.value)), original = history.find((item) => item.revision === current.revision); if (!source || !original) {message("请读取历史版本，并选择有效来源", true); return;} preview({id: crypto.randomUUID(), action: "request_save_rollback", target: owner, reason: reason.value, expected_version: data.controls.version, maintenance_id: data.maintenance.id, slot: slot.value, expected_revision: current.revision, expected_sha256: original.sha256, restore_revision: source.revision, restore_sha256: source.sha256}, [["玩家 / 槽位", data.player.nickname + " / " + slot.value], ["当前云档版本", current.revision], ["恢复来源版本", source.revision + " / " + time(source.updated)], ["执行后的云档版本", current.revision + 1], ["可信资产处理", "全部保持当前状态"], ["复核要求", "另一位经济管理员独立复核"], ["依据", reason.value]]);});
  }
  const list = el("div"), loadReviews = button("查看此玩家的回滚申请", async () => {loadReviews.disabled = true; try {const result = await api("save-rollbacks?" + new URLSearchParams({target: owner})); if (!list.isConnected) return; list.replaceChildren(); table(list, ["申请 / 来源", "申请人", "影响预览", "状态", "操作"], result.proposals.map((proposal) => {const instruction = proposal.detail.instruction, inspect = el("details"); inspect.append(el("summary", "查看版本与资产保留范围"), el("pre", JSON.stringify({before: proposal.detail.before, after: proposal.detail.after, preserved: proposal.detail.fence.preserved, reason: instruction.reason}, null, 2))); const actions = el("div", null, "toolbar"); if (proposal.status === "pending" && proposal.expires > result.as_of && proposal.actor !== state.admin.username) actions.append(button("复核并回滚整档", () => preview({id: crypto.randomUUID(), action: "approve_save_rollback", reason: ("复核整档回滚：" + instruction.reason).slice(0, 500), proposal_id: proposal.id}, [["申请人", proposal.actor], ["玩家 / 槽位", owner + " / " + instruction.slot], ["版本变化", instruction.expected_revision + " → " + (instruction.expected_revision + 1) + "，内容来自版本 " + instruction.restore_revision], ["快照金币", number(proposal.detail.before.money) + " → " + number(proposal.detail.after.money)], ["受控资产", "全部保留当前状态；执行前再次核对"], ["回滚依据", instruction.reason]]), "danger")); if (proposal.status === "pending" && (proposal.actor === state.admin.username || state.admin.role === "admin")) actions.append(button("取消回滚申请", () => preview({id: crypto.randomUUID(), action: "cancel_save_rollback", reason: ("取消回滚申请：" + instruction.reason).slice(0, 500), proposal_id: proposal.id}, [["申请编号", proposal.id], ["操作", "取消申请，保留当前云档"]]))); return [proposal.id + " / " + instruction.slot + " / 历史版本 " + instruction.restore_revision, proposal.actor, inspect, proposal.status === "pending" && proposal.expires <= result.as_of ? "已过期" : proposal.status, actions];}));} catch (error) {message(error.message, true);} finally {loadReviews.disabled = false;}});
  box.append(loadReviews, list);
}
function economy(data) {
  const report = data.report, toolbar = el("div", null, "toolbar"), select = el("select"); select.setAttribute("aria-label", "经济报表币种");
  [["GOLD", "受控角色金币 GOLD"], ["MARKET", "联机币 MARKET"], ["RP", "商城点券 RP"]].forEach(([value, label]) => {const option = el("option", label); option.value = value; select.append(option);}); select.value = state.currency; select.addEventListener("change", () => {state.currency = select.value; state.cursor = null; render();}); toolbar.append(select, el("span", "服务端账本 · " + time(report.as_of), "muted small")); $("content").append(toolbar);
  const cards = el("div", null, "cards"); [["玩家持有总额", report.player_total], ["累计发行", report.issued], ["累计回收销毁", report.retired], ["发行减销毁", report.outstanding_supply]].forEach(([label, value]) => {const node = el("div", null, "metric"); node.append(el("div", label, "label"), el("div", number(value), "value")); cards.append(node);}); $("content").append(cards);
  $("content").append(el("p", "主线金币、联机币、点券分别统计。余额、对账和排行榜显示当前状态，日期筛选作用于收支与流水。商城点券消费进入系统账户；真实支付尚未接入，不计现金收入。", "notice"));
  const check = panel("经济对账"); check.append(badge(report.reconciliation.ok ? "账本一致" : "发现差异，需要调查", report.reconciliation.ok ? "" : "error")); details(check, [["可用余额合计", number(report.available_total)], ["冻结 / 封禁 / 维护占用", number(report.frozen_total)]]); if (!report.reconciliation.ok) check.append(el("pre", JSON.stringify(report.reconciliation, null, 2)));
  const period = report.period, periodBox = panel("区间收入与上一期对比"), form = el("form", null, "toolbar"), preset = el("select"), from = el("input"), to = el("input");
  [["today", "今日"], ["yesterday", "昨日"], ["7d", "近 7 天"], ["30d", "近 30 天"], ["custom", "自定义日期"]].forEach(([value, text]) => {const option = el("option", text); option.value = value; preset.append(option);}); preset.value = state.period;
  from.type = to.type = "date"; from.required = to.required = true; from.value = period.start_day; to.value = period.end_day; const toggle = () => {from.disabled = to.disabled = preset.value !== "custom";}; preset.addEventListener("change", toggle); toggle();
  [["日期区间", preset], ["开始日期", from], ["结束日期", to]].forEach(([text, input]) => {const label = el("label", text); label.append(input); form.append(label);}); const apply = el("button", "查询区间", "primary"); apply.type = "submit"; form.append(apply); periodBox.append(form);
  form.addEventListener("submit", (event) => {event.preventDefault(); state.period = preset.value; state.start = from.value; state.end = to.value; state.cursor = null; render();});
  periodBox.append(el("p", period.start_day + " 至 " + period.end_day + "；对比 " + period.previous_start_day + " 至 " + period.previous_end_day + "。" + (period.partial_day ? "今日尚未结束，上期只计算到对应时刻。" : "按完整自然日计算。") + " 最多查询 90 天，日期均为 Asia/Shanghai。", "muted small"));
  if (!period.coverage_complete || !period.previous_coverage_complete) periodBox.append(el("p", "本期或上期未覆盖完整历史；以下仅列已保留的账本记录，不计算增长率。已知采集起始：" + time(period.known_since), "notice"));
  table(periodBox, ["指标", "本期记录", "上期记录", "变化"], [["issued", "发行产出"], ["retired", "回收销毁"], ["shop_net_spend", "商城净消费"], ["market_volume", "市场成交额"], ["market_trades", "市场成交笔数"]].map(([key, label]) => {const current = report.period_totals[key], previous = report.previous_totals[key], comparable = period.coverage_complete && period.previous_coverage_complete; const change = comparable ? previous ? ((current - previous) / Math.abs(previous) * 100).toFixed(2) + "%" : current ? "上期无基数" : "0.00%" : "历史未完整覆盖"; return [label, number(current), number(previous), change];}));
  table(panel("区间来源与去向"), ["来源", "进入玩家", "离开玩家", "事件数"], report.sources.map((row) => [row.source, number(row.to_players), number(row.from_players), row.events]));
  table(panel("系统账户"), ["账户", "余额"], Object.entries(report.system_balances).map(([account, balance]) => [account, number(balance)]));
  table(panel("余额前 20 名"), ["玩家 / 角色", "余额", "钱包版本"], report.top_wallets.map((wallet) => [button(wallet.nickname + (wallet.character_name ? " / " + wallet.character_name : "") + " / " + wallet.owner, () => {state.player = wallet.account_id || wallet.owner; state.page = "detail"; render();}, "link"), number(wallet.balance), wallet.revision]));
  if (state.admin.permissions.includes("economy")) {
    table(panel("大额调整复核"), ["申请编号", "申请人", "内容", "状态", "操作"], report.proposals.map((proposal) => {
      const command = JSON.parse(proposal.document), canApprove = proposal.status === "pending" && proposal.expires > report.as_of && proposal.actor !== state.admin.username;
      return [proposal.id, proposal.actor, command.target + " / " + command.currency + " / " + command.amount, proposal.status === "pending" && proposal.expires <= report.as_of ? "已过期" : proposal.status,
        canApprove ? button("复核并执行", () => preview({id: crypto.randomUUID(), action: "approve_wallet", target: command.target, reason: ("复核 " + proposal.id + "：" + command.reason).slice(0, 500), expected_version: command.expected_version, proposal_id: proposal.id}, [["目标", command.target], ["申请人", proposal.actor], ["币种 / 增减量", command.currency + " / " + command.amount], ["申请原因", command.reason]]), "link") : "—"];
    }));
  }
  const ledger = panel("经济流水"); table(ledger, ["编号 / 时间", "玩家", "变动", "变动后余额", "来源事件"], data.ledger.entries.map((entry) => [entry.id + " / " + time(entry.created), entry.owner, number(entry.amount), number(entry.balance), entry.event]));
  if (state.admin.permissions.includes("export")) ledger.append(button("导出当前币种流水", () => startExport("ledger")));
  const actions = el("div", null, "actions"); if (data.ledger.next_cursor) actions.append(button("更早流水", () => {state.cursor = data.ledger.next_cursor; render();})); if (state.cursor) actions.append(button("最新流水", () => {state.cursor = null; render();})); ledger.append(actions);
}
function marketPrices(data) {
  const currency = el("select"); [["MARKET", "托管收藏 MARKET"], ["GOLD", "原版受控 GOLD"]].forEach(([value, text]) => {const option = el("option", text); option.value = value; currency.append(option);}); currency.value = data.currency; currency.addEventListener("change", () => {state.priceCurrency = currency.value; render();}); const currencyLabel = el("label", "价格分析币种"); currencyLabel.append(currency); $("content").append(currencyLabel);
  const filters = panel("成交样本筛选"), form = el("form", null, "control-form"), period = el("select"), from = el("input"), to = el("input"), species = el("input"), low = el("input"), high = el("input"), shiny = el("select"), iv = el("input");
  [["today", "今日"], ["yesterday", "昨日"], ["7d", "近 7 天"], ["30d", "近 30 天"], ["custom", "自定义日期"]].forEach(([value, text]) => {const option = el("option", text); option.value = value; period.append(option);}); period.value = state.pricePeriod;
  from.type = to.type = "date"; from.value = data.period.start_day; to.value = data.period.end_day; from.required = to.required = true; const toggle = () => {from.disabled = to.disabled = period.value !== "custom";}; period.addEventListener("change", toggle); toggle();
  species.placeholder = "留空为全部，例如 B6H9 或 PIKACHU"; species.value = state.priceSpecies; species.maxLength = 64;
  for (const input of [low, high, iv]) {input.type = "number"; input.required = true; input.step = "1";} low.min = high.min = "1"; low.max = high.max = "100"; iv.min = "0"; iv.max = "186"; low.value = state.priceMinLevel; high.value = state.priceMaxLevel; iv.value = state.priceMinIV;
  [["any", "全部"], ["0", "普通"], ["1", "异色"]].forEach(([value, text]) => {const option = el("option", text); option.value = value; shiny.append(option);}); shiny.value = state.priceShiny;
  [["统计区间", period], ["物种 / 融合编号", species], ["开始日期", from], ["结束日期", to], ["最低等级", low], ["最高等级", high], ["异色", shiny], ["最低个体值总和", iv]].forEach(([text, input]) => {const label = el("label", text); label.append(input); form.append(label);}); const submit = el("button", "查询成交价格", "primary"); submit.type = "submit"; form.append(submit); filters.append(form);
  form.addEventListener("submit", (event) => {event.preventDefault(); Object.assign(state, {pricePeriod: period.value, priceStart: from.value, priceEnd: to.value, priceSpecies: species.value.trim().toUpperCase(), priceMinLevel: Number(low.value), priceMaxLevel: Number(high.value), priceShiny: shiny.value, priceMinIV: Number(iv.value)}); render();});
  $("content").append(el("p", "仅统计已核对买卖双方扣款的 " + data.currency + " 成交，每个挂牌只计算一次。分位数采用最近秩方法；当前挂牌价独立显示。不同特性、性格与招式仍会影响价格，统计结果不作为自动处罚依据。", "notice"));
  const cards = el("div", null, "cards"); [["成交笔数", data.summary.trades], ["成交总额 " + data.currency, data.summary.volume], ["成交中位价", data.summary.median], ["成交 P90", data.summary.p90]].forEach(([label, value]) => {const card = el("div", null, "metric"); card.append(el("div", label, "label"), el("div", number(value), "value")); cards.append(card);}); $("content").append(cards);
  const basis = panel("样本覆盖与当前挂牌"); details(basis, [["成交日期", data.period.start_day + " 至 " + data.period.end_day], ["独立资产 / 买家 / 卖家", data.summary.distinct_assets + " / " + data.summary.buyers + " / " + data.summary.sellers], ["当前有效挂牌", data.active_asks.count], ["当前挂牌中位价", number(data.active_asks.median)], ["成交等待时间中位数", data.summary.median_seconds_to_sell === null ? "未采集" : number(data.summary.median_seconds_to_sell) + " 秒"], ["采集起始", time(data.period.known_since)]]);
  if (!data.integrity.ok) basis.append(el("p", "存在未核对成交或账本差异，结果仅覆盖已验证记录：" + JSON.stringify(data.integrity), "notice"));
  const comparable = data.period.coverage_complete && data.period.previous_coverage_complete;
  basis.append(el("p", comparable ? "上期为 " + data.period.previous_start_day + " 至 " + data.period.previous_end_day + (data.period.partial_day ? "，计算到对应时刻。" : "。") : "本期或上期历史未完整覆盖，以下只列已保存记录。", "muted small"));
  table(basis, ["指标", "本期记录", "上期记录"], [["成交笔数", number(data.summary.trades), number(data.previous_summary.trades)], ["成交总额", number(data.summary.volume), number(data.previous_summary.volume)], ["成交中位价", number(data.summary.median), number(data.previous_summary.median)]]);
  const trend = panel("每日成交中位价与成交量");
  if (data.daily.length) {
    const ns = "http://www.w3.org/2000/svg", svg = document.createElementNS(ns, "svg"); svg.setAttribute("viewBox", "0 0 800 180"); svg.setAttribute("role", "img"); svg.setAttribute("aria-label", "所选样本的每日成交中位价"); svg.classList.add("price-chart");
    const values = data.daily.map((row) => row.median), minimum = Math.min(...values), maximum = Math.max(...values), points = data.daily.map((row, index) => ({x: 45 + index * 710 / Math.max(1, data.daily.length - 1), y: maximum === minimum ? 82 : 145 - (row.median - minimum) * 120 / (maximum - minimum), row}));
    const line = document.createElementNS(ns, "polyline"); line.setAttribute("points", points.map((point) => point.x + "," + point.y).join(" ")); line.setAttribute("fill", "none"); line.setAttribute("stroke", "#087e83"); line.setAttribute("stroke-width", "3"); svg.append(line);
    points.forEach((point) => {const dot = document.createElementNS(ns, "circle"), title = document.createElementNS(ns, "title"); dot.setAttribute("cx", point.x); dot.setAttribute("cy", point.y); dot.setAttribute("r", "5"); dot.setAttribute("fill", "#087e83"); title.textContent = point.row.day + " · 中位价 " + number(point.row.median) + " · 成交 " + point.row.trades + " 笔"; dot.append(title); svg.append(dot);});
    [[data.daily[0].day, 45, 173], [data.daily[data.daily.length - 1].day, 650, 173], [number(maximum), 3, 20], [number(minimum), 3, 150]].forEach(([text, x, y]) => {const label = document.createElementNS(ns, "text"); label.textContent = text; label.setAttribute("x", x); label.setAttribute("y", y); label.setAttribute("font-size", "12"); label.setAttribute("fill", "#69808f"); svg.append(label);}); trend.append(svg);
  }
  table(trend, ["日期", "笔数", "成交额", "中位价", "P10", "P90"], data.daily.map((row) => [row.day, row.trades, number(row.volume), number(row.median), number(row.p10), number(row.p90)]));
  const groups = panel("按物种、等级、异色与个体值分组"); groups.append(el("p", "样本充足需至少 5 笔、3 只独立资产和 3 名买家。显示成交额前 100 组，共 " + data.group_count + " 组" + (data.groups_limited ? "；请缩小筛选查看其余组。" : "。"), "muted small"));
  table(groups, ["物种 / 等级 / 品质", "笔数 / 独立资产", "中位价", "P25～P75", "P10～P90", "成交额", "样本"], data.groups.map((row) => [row.species + " / Lv." + row.min_level + "～" + row.max_level + " / " + (row.shiny ? "异色" : "普通") + " / IV " + row.iv_band, row.trades + " / " + row.distinct_assets, number(row.median), number(row.p25) + "～" + number(row.p75), number(row.p10) + "～" + number(row.p90), number(row.volume), badge(row.sufficient_sample ? "充足" : "不足", row.sufficient_sample ? "" : "warning")]));
  table(panel("最近 50 笔已核对成交"), ["挂牌 / 资产", "物种 / 等级", "成交价", "时间"], data.recent_sales.map((row) => [row.listing_id + " / " + row.asset_id, row.species + " / " + row.level, number(row.price), time(row.sold_at)]));
  if (state.admin.permissions.includes("export")) $("content").append(button("导出所选成交样本 CSV", async () => {try {const result = await api("exports", {id: crypto.randomUUID(), kind: "market_sales", ...priceFilter()}); message("成交导出任务已提交 · " + result.id); state.page = "exports"; state.cursor = null; render();} catch (error) {message(error.message, true);}}, "primary"));
}
function transactions(data) {
  const box = panel(), toolbar = el("div", null, "toolbar"), select = el("select"); select.setAttribute("aria-label", "业务记录类型");
  [["shop", "商城订单"], ["market", "托管收藏市场回执"], ["original_market", "原版 GOLD 挂牌与交付"], ["original_trade", "原版双方交易"]].forEach(([value, label]) => {const node = el("option", label); node.value = value; select.append(node);}); select.value = state.transactionKind; select.addEventListener("change", () => {state.transactionKind = select.value; state.cursor = null; render();}); toolbar.append(select); box.append(toolbar);
  table(box, ["游标", "玩家", "业务记录"], data.transactions.map((item) => [item.cursor, item.owner, el("pre", JSON.stringify(item.detail, null, 2))]));
  if (data.transactions.length === 50) box.append(button("更早记录", () => {state.cursor = data.transactions[data.transactions.length - 1].cursor; render();})); if (state.cursor) box.append(button("最新记录", () => {state.cursor = null; render();}));
}
function retention(data) {
  $("content").append(el("p", "按首次观察到的有效游戏活动日期分组；统计接入前的历史无法追溯。尚未到达观察日期的留存显示“未到期”。", "notice"));
  const rate = (count, total) => count === null ? "未到期" : number(count) + " / " + total + "（" + (count / total * 100).toFixed(1) + "%）";
  table(panel("首次活跃账号分组 · Asia/Shanghai"), ["首次活跃日期", "账号数", "次日留存", "7 日留存", "30 日留存"], data.cohorts.map((row) => [row.cohort, row.accounts, rate(row.d1, row.accounts), rate(row.d7, row.accounts), rate(row.d30, row.accounts)]));
}
function alerts(data) {
  $("content").append(el("p", "最近检测：" + time(data.last_scan) + "。告警保留规则与证据，调查处理不会自动封号；标记解决也不会修改经济账本。", "notice"));
  const controls = panel("调查操作"); controls.append(el("p", "选择一条告警开始调查。", "muted"));
  table(panel("风险案件（最多显示 100 条）"), ["规则 / 编号", "级别", "状态", "证据", "操作"], data.alerts.map((alert) => {
    const evidence = el("details"); evidence.append(el("summary", "查看证据"), el("pre", JSON.stringify(alert.evidence, null, 2)));
    return [alert.rule + " / " + alert.id, badge(alert.severity, alert.severity === "error" ? "error" : "warning"), alert.status + (alert.present ? " · 当前仍存在" : " · 当前已消失"), evidence,
      state.admin.permissions.includes("moderate") ? button("处理案件", () => {controls.replaceChildren(el("h2", alert.id)); const form = el("form", null, "control-form"), status = el("select"), reason = el("textarea"); [["investigating", "调查中"], ["resolved", "已解决"], ["open", "待调查"]].forEach(([value, text]) => {const item = el("option", text); item.value = value; status.append(item);}); reason.required = true; reason.minLength = 3; reason.maxLength = 500; const ls = el("label", "处理状态"), lr = el("label", "调查说明", "wide"); ls.append(status); lr.append(reason); const submit = el("button", "预览案件处理", "primary"); submit.type = "submit"; form.append(ls, lr, submit); form.addEventListener("submit", (event) => {event.preventDefault(); preview({id: crypto.randomUUID(), action: "alert_status", target: alert.id, reason: reason.value, expected_version: alert.version, status: status.value}, [["案件", alert.id], ["证据版本", alert.version], ["状态", status.selectedOptions[0].textContent], ["说明", reason.value]]);}); controls.append(form); controls.scrollIntoView({behavior: "smooth"});}, "link") : "—"];
  }));
}
async function startExport(kind, target = "") {try {const result = await api("exports", {id: crypto.randomUUID(), kind, target, currency: state.currency, ...(kind === "ledger" ? periodFilter() : {})}); message("导出任务已提交 · " + result.id); state.page = "exports"; state.cursor = null; render();} catch (error) {message(error.message, true);}}
async function downloadExport(id) {try {const data = await api("exports/" + id); if (data.status !== "ready") {message("导出状态：" + data.status + (data.result?.error ? " / " + data.result.error : ""), true); return;} const link = el("a"), url = URL.createObjectURL(new Blob([data.result.csv], {type: "text/csv;charset=utf-8"})); link.href = url; link.download = data.result.filename; document.body.append(link); link.click(); link.remove(); setTimeout(() => URL.revokeObjectURL(url), 1000);} catch (error) {message(error.message, true);}}
function exportsPage(data) {
  state.exportPending = data.exports.some((job) => ["pending", "working"].includes(job.status));
  $("content").append(el("p", "常规流水默认：" + state.currency + " / " + ({today: "今日", yesterday: "昨日", "7d": "近 7 天", "30d": "近 30 天", custom: state.start + " 至 " + state.end})[state.period] + "。每项导出的实际币种和筛选条件以任务列表为准。", "notice"));
  const box = panel("生成报表"); box.append(el("p", "导出使用一致性快照，每份最多 5,000 行，结果保留 24 小时。超过限制时任务失败，可从玩家详情导出指定账号的数据。", "muted small")); const toolbar = el("div", null, "toolbar"); [["players", "导出全部玩家"], ["ledger", "导出当前币种流水"], ["audit", "导出操作审计"]].forEach(([kind, label]) => toolbar.append(button(label, () => startExport(kind)))); box.append(toolbar);
  table(panel("我的导出任务"), ["任务编号", "类型 / 筛选", "状态", "创建时间", "到期时间", "操作"], data.exports.map((job) => {const filters = job.filters || {}, scope = ["ledger", "market_sales"].includes(job.kind) ? filters.currency + (job.kind === "market_sales" ? " 成交 / " + (filters.species || "全部物种") + " / Lv." + filters.min_level + "～" + filters.max_level + " / 异色 " + filters.shiny + " / IV≥" + filters.min_iv : "") + " / " + (filters.start ? filters.start + " 至 " + filters.end : "全部已保留日期") : job.kind; return [job.id, scope + (filters.target ? " / " + filters.target : ""), job.status, time(job.created), time(job.expires), job.status === "ready" ? button("下载 CSV", () => downloadExport(job.id), "link") : job.status === "failed" ? button("查看错误", () => downloadExport(job.id), "link") : "—"]; }));
}
function batchesPage(data) {
  const box = panel("新建批量调整"), form = el("form", null, "control-form"), currency = el("select"), recipients = el("textarea"), reason = el("textarea");
  ["MARKET", "RP", "GOLD"].forEach((name) => {const option = el("option", name); option.value = name; currency.append(option);}); recipients.required = true; recipients.maxLength = 6000; recipients.placeholder = "每行：玩家 ID,增减数量；GOLD 使用 cc_ 开头的受控角色 ID"; reason.required = true; reason.minLength = 3; reason.maxLength = 500;
  [["币种", currency, ""], ["目标清单（最多 50 个钱包）", recipients, "wide"], ["活动或补偿依据", reason, "wide"]].forEach(([label, input, cls]) => {const node = el("label", label, cls); node.append(input); form.append(node);}); const submit = el("button", "读取余额并预览批次", "primary"); submit.type = "submit"; form.append(submit); box.append(el("p", "每个批次必须由另一名有经济权限的管理员复核。执行时重新核对全部账号与钱包版本；任何一项冲突都会使整个批次不执行。", "notice"), form);
  form.addEventListener("submit", async (event) => {event.preventDefault(); submit.disabled = true; try {const lines = recipients.value.trim().split(/\r?\n/).filter((line) => line.trim()); if (!lines.length || lines.length > 50) throw new Error("选择 1～50 个钱包"); const gold = currency.value === "GOLD", parsed = lines.map((line) => {const parts = line.split(",").map((part) => part.trim()); if (parts.length !== 2 || !(gold ? /^cc_[a-f0-9]{32}$/ : /^p_[a-f0-9]{24}$/).test(parts[0]) || !/^-?[0-9]+$/.test(parts[1]) || !Number.isSafeInteger(Number(parts[1])) || Number(parts[1]) === 0) throw new Error("编号或数量格式错误"); return {key: parts[0], amount: Number(parts[1])};}); if (new Set(parsed.map((item) => item.key)).size !== parsed.length) throw new Error("清单中不能重复出现同一个钱包"); const snapshot = await api("batch-preview?" + new URLSearchParams({currency: currency.value, [gold ? "characters" : "owners"]: parsed.map((item) => item.key).join(",")})); const keyFor = (entry) => entry.character_id || entry.owner; const rows = parsed.map((item) => {const current = snapshot.recipients.find((entry) => keyFor(entry) === item.key); return {owner: current.owner, amount: item.amount, expected_control_version: current.expected_control_version, expected_wallet_revision: current.expected_wallet_revision, ...(gold ? {character_id: current.character_id} : {})};}); preview({id: crypto.randomUUID(), action: "batch_wallet", reason: reason.value, currency: currency.value, recipients: rows}, [["币种", currency.value], ["原因", reason.value], ...rows.map((item) => [keyFor(item), number(snapshot.recipients.find((entry) => keyFor(entry) === keyFor(item)).balance) + " → " + number(snapshot.recipients.find((entry) => keyFor(entry) === keyFor(item)).balance + item.amount)])]);} catch (error) {message(error.message, true);} finally {submit.disabled = false;}});
  table(panel("最近批次"), ["批次编号", "申请人", "币种 / 钱包数", "清单与原因", "状态", "操作"], data.batches.map((batch) => {const detail = el("details"); detail.append(el("summary", "查看申请"), el("pre", JSON.stringify(batch.detail, null, 2))); const canApprove = batch.status === "pending" && batch.expires > data.as_of && batch.actor !== state.admin.username; return [batch.id, batch.actor, batch.detail.currency + " / " + batch.detail.recipients.length, detail, batch.status === "pending" && batch.expires <= data.as_of ? "已过期" : batch.status, canApprove ? button("复核整个批次", () => preview({id: crypto.randomUUID(), action: "approve_batch", reason: ("复核批次 " + batch.id + "：" + batch.detail.reason).slice(0, 500), proposal_id: batch.id}, [["申请人", batch.actor], ["原因", batch.detail.reason], ["币种", batch.detail.currency], ...batch.detail.recipients.map((item) => [item.character_id || item.owner, item.amount])]), "link") : "—"]; }));
}
function commercePage(data) {
  const reason = el("input"); reason.required = true; reason.minLength = 3; reason.maxLength = 500; reason.placeholder = "运营维护原因或工单编号";
  const controls = panel("业务开关"), label = el("label", "变更原因"); label.append(reason); controls.append(label);
  const names = {paused: "商城购买", market_paused: "市场新增交易", equipment_paused: "商城装备变更"};
  const buttons = el("div", null, "toolbar"); data.controls.forEach((control) => buttons.append(button((control.value ? "恢复" : "暂停") + names[control.key], () => {if (reason.value.trim().length < 3) {message("请填写变更原因", true); return;} preview({id: crypto.randomUUID(), action: "commerce_control", reason: reason.value, expected_hash: control.hash, data: {key: control.key, value: !control.value}}, [["业务", names[control.key]], ["变更后", control.value ? "开放" : "暂停新增操作"], ["原因", reason.value]]);}))); controls.append(buttons);
  const products = panel("商品上下架与价格"), product = el("select"), price = el("input"), enabled = el("input");
  data.products.forEach((entry, index) => {const option = el("option", entry.product.name + " / " + entry.product.id); option.value = String(index); product.append(option);}); price.type = "number"; price.required = true; price.min = "1"; price.max = "1000000000"; enabled.type = "checkbox";
  const form = el("form", null, "control-form"); [["商品", product], ["点券价格", price], ["允许上架", enabled]].forEach(([text, input]) => {const item = el("label", text); item.append(input); form.append(item);});
  const submit = el("button", "预览商品变更", "primary"); submit.type = "submit"; form.append(submit); products.append(form);
  const selectProduct = () => {const entry = data.products[Number(product.value)]; if (entry) {price.value = entry.product.price; enabled.checked = entry.product.enabled !== false;}}; product.addEventListener("change", selectProduct); selectProduct();
  form.addEventListener("submit", (event) => {event.preventDefault(); if (reason.value.trim().length < 3) {message("请在业务开关处填写变更原因", true); return;} const entry = data.products[Number(product.value)]; if (!entry) return; preview({id: crypto.randomUUID(), action: "commerce_control", reason: reason.value, expected_hash: entry.hash, data: {key: entry.key, value: {...(entry.override || {}), enabled: enabled.checked, price: Number(price.value)}}}, [["商品", entry.product.name], ["价格", entry.product.price + " → " + price.value], ["上架", enabled.checked ? "是" : "否"], ["原因", reason.value]]);});
  const codeBox = panel("创建兑换码（需要独立复核）"), codeForm = el("form", null, "control-form"), code = el("input"), currency = el("select"), amount = el("input"), maximum = el("input"), days = el("input"), batch = el("input"), codeReason = el("textarea");
  code.value = "KIF-" + Array.from(crypto.getRandomValues(new Uint8Array(16)), (value) => value.toString(16).padStart(2, "0")).join("").toUpperCase(); code.readOnly = true; ["RP", "MARKET"].forEach((name) => {const option = el("option", name); option.value = name; currency.append(option);});
  for (const input of [amount, maximum, days]) {input.type = "number"; input.min = "1"; input.required = true;} amount.max = "1000000000"; maximum.max = "100000"; days.max = "365"; days.value = "7"; maximum.value = "1"; batch.required = true; batch.maxLength = 80; codeReason.required = true; codeReason.minLength = 3; codeReason.maxLength = 500;
  [["兑换码（请在提交前复制保存）", code, "wide"], ["币种", currency, ""], ["每账号领取数量", amount, ""], ["最多领取账号数", maximum, ""], ["有效天数", days, ""], ["活动批次名称", batch, "wide"], ["发放依据", codeReason, "wide"]].forEach(([text, input, cls]) => {const item = el("label", text, cls); item.append(input); codeForm.append(item);});
  const create = el("button", "预览兑换码申请", "primary"); create.type = "submit"; codeForm.append(create); codeBox.append(el("p", "服务端仅保留兑换码哈希。申请提交后尚不能领取，另一名管理员复核激活后生效。", "notice"), codeForm);
  codeForm.addEventListener("submit", (event) => {event.preventDefault(); const expires = Math.floor(data.as_of) + Number(days.value) * 86400; preview({id: crypto.randomUUID(), action: "create_code", reason: codeReason.value, data: {code: code.value, currency: currency.value, amount: Number(amount.value), maximum: Number(maximum.value), expires, batch: batch.value}}, [["兑换码", code.value], ["币种 / 单次数量", currency.value + " / " + amount.value], ["账号上限", maximum.value], ["到期时间", time(expires)], ["批次", batch.value], ["原因", codeReason.value]]);});
  const refunds = panel("订单退款与挂牌撤销"), refundForm = el("form", null, "control-form"), order = el("input"), playerMessage = el("input"), refundReason = el("textarea");
  order.required = true; order.maxLength = 80; playerMessage.required = true; playerMessage.maxLength = 200; playerMessage.value = "商城订单退款"; refundReason.required = true; refundReason.minLength = 3; refundReason.maxLength = 500;
  [["商城订单编号", order], ["退款说明（玩家可见）", playerMessage], ["内部退款依据", refundReason]].forEach(([text, input]) => {const item = el("label", text); item.append(input); refundForm.append(item);}); const refundButton = el("button", "读取订单并预览退款", "primary"); refundButton.type = "submit"; refundForm.append(refundButton); refunds.append(refundForm);
  refundForm.addEventListener("submit", async (event) => {event.preventDefault(); refundButton.disabled = true; try {const snapshot = await api("commerce-order?" + new URLSearchParams({order_id: order.value})); preview({id: crypto.randomUUID(), action: "refund_order", reason: refundReason.value, data: {order_id: order.value, expected_wallet_revision: snapshot.wallet.revision, player_message: playerMessage.value}}, [["目标账号", snapshot.owner], ["订单状态", snapshot.order.status], ["退还点券", snapshot.order.total], ["当前钱包余额", snapshot.wallet.balance], ["处理方式", "独立复核后退点券并撤销该订单权益"]]);} catch (error) {message(error.message, true);} finally {refundButton.disabled = false;}});
  const cancelForm = el("form", null, "control-form"), listing = el("input"), cancelReason = el("textarea"); listing.required = true; listing.maxLength = 80; cancelReason.required = true; cancelReason.minLength = 3; cancelReason.maxLength = 500;
  [["市场挂牌编号", listing], ["撤销依据（内部）", cancelReason]].forEach(([text, input]) => {const item = el("label", text); item.append(input); cancelForm.append(item);}); const cancel = el("button", "读取挂牌并预览撤销"); cancel.type = "submit"; cancelForm.append(cancel); refunds.append(cancelForm);
  cancelForm.addEventListener("submit", async (event) => {event.preventDefault(); cancel.disabled = true; try {const snapshot = await api("commerce-listing?" + new URLSearchParams({listing_id: listing.value})); preview({id: crypto.randomUUID(), action: "cancel_listing", reason: cancelReason.value, reference: listing.value}, [["所有者", snapshot.listing.owner], ["资产", snapshot.listing.asset_id], ["状态", snapshot.listing.status], ["金额", snapshot.listing.price]]);} catch (error) {message(error.message, true);} finally {cancel.disabled = false;}});
  table(panel("兑换码批次（仅显示哈希）"), ["批次 / 哈希", "币种 / 数量", "已用 / 上限", "到期时间", "操作"], data.codes.map((item) => [item.batch + " / " + item.hash, item.currency + " / " + item.amount, item.uses + " / " + item.maximum, time(item.expires), button("停止后续领取", () => {if (reason.value.trim().length < 3) {message("请填写变更原因", true); return;} preview({id: crypto.randomUUID(), action: "disable_code", reason: reason.value, reference: item.hash, expected_hash: item.configuration_hash}, [["批次", item.batch], ["兑换码哈希", item.hash], ["操作", "停止新领取，并取消待激活申请"]]);}, "link")]));
  table(panel("运营操作复核"), ["申请编号", "申请人", "类型", "申请内容", "状态", "操作"], data.proposals.map((proposal) => {const detail = el("details"); detail.append(el("summary", "查看申请"), el("pre", JSON.stringify(proposal.detail, null, 2))); const canApprove = proposal.status === "pending" && proposal.expires > data.as_of && proposal.actor !== state.admin.username; return [proposal.id, proposal.actor, proposal.action, detail, proposal.status === "pending" && proposal.expires <= data.as_of ? "已过期" : proposal.status, canApprove ? button("复核并执行", () => preview({id: crypto.randomUUID(), action: "approve_commerce", reason: ("复核 " + proposal.id + "：" + proposal.detail.reason).slice(0, 500), proposal_id: proposal.id}, [["申请人", proposal.actor], ["类型", proposal.action], ["原因", proposal.detail.reason], ["操作参数", JSON.stringify(proposal.detail.data)]]), "link") : "—"]; }));
}
$("login-form").addEventListener("submit", async (event) => {event.preventDefault(); const submit = event.submitter; submit.disabled = true; try {const data = await api("login", {username: $("username").value, password: $("password").value, otp: $("otp").value}); state.token = data.token; state.admin = data.administrator; state.page = "overview"; state.cursor = null; $("password").value = ""; $("otp").value = ""; $("login-panel").hidden = true; $("workspace").hidden = false; $("message").hidden = true; document.querySelector('[data-page="exports"]').hidden = !state.admin.permissions.includes("export"); for (const page of ["batches", "commerce", "controlled"]) document.querySelector('[data-page="' + page + '"]').hidden = !state.admin.permissions.includes("economy"); $("administrator").textContent = state.admin.username + " · " + state.admin.role; await render();} catch (error) {message(error.message, true);} finally {submit.disabled = false;}});
$("logout").addEventListener("click", async () => {try {await api("logout", {}); reset();} catch (error) {message("退出未确认：" + error.message, true);}});
$("refresh").addEventListener("click", render);
document.querySelectorAll("[data-page]").forEach((node) => node.addEventListener("click", () => {if (state.busy) return; state.page = node.dataset.page; state.cursor = null; render();}));
$("cancel-command").addEventListener("click", () => {state.pending = null; $("confirmation").close();});
$("execute-command").addEventListener("click", async () => {const submit = $("execute-command"); if (!state.pending) return; submit.disabled = true; try {const result = await api("commands", state.pending); state.pending = null; state.dataVersion++; $("confirmation").close(); message((result.status === "pending_approval" ? "申请已提交，等待另一名管理员复核" : "操作已完成") + " · " + result.command_id); await render();} catch (error) {message(error.message + "。若结果未知，请保留此确认框并重试原指令。", true);} finally {submit.disabled = false;}});
setInterval(() => {if (state.token && state.page === "overview" && !document.hidden) render();}, 30000);
setInterval(() => {if (state.token && state.page === "exports" && state.exportPending && !document.hidden) render();}, 5000);
