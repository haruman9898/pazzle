class_name TownWorld
extends RefCounted
## ステージ1（交差点4つ）のシミュレーション本体。純ロジック（見た目に依存しない）。
## 1交差点の SimWorld と同じ約束で、車・歩行者・信号・不満度を道路網全体に広げたもの。
##   - 建物から出る人は、固定の予定表どおりに出発する（予報は約束）。ランダムなのは通過交通の量だけ
##   - 車は経路上の交差点ごとに予約し、出口が空いているときだけ進入する
##   - 歩行者は目的地ごとの距離場で経路を決める。道路に入るときに迂回距離の分だけ余計に費用がかかる
##   - 信号は交差点用と路上用。同じ道路・同じ間隔の近い信号は、自動で連動する

const KIND_CAR := 0
const KIND_PED := 1
const J_NONE := -1

class Car:
	var id: int
	var kind := 0
	var pts: PackedVector2Array
	var jc: Array              # 経路上の交差点 [{j, arm_in, s_stop, s_req, s_box_in, s_box_out, quads, state}]
	var ji := 0                # 次に通る交差点の番号
	var pieces: Array          # 経路の直線部分 [{l, c0, c1, s0}]（路上の信号を探すのに使う）
	var s := 0.0
	var v := 0.0
	var pos := Vector2.ZERO
	var dir := Vector2.RIGHT
	var d := 0.0
	var t_alive := 0.0
	var expected := 1.0
	var waiting := false
	var wait_t := 0.0
	var stopped_total := 0.0
	var at_red := false        # 赤信号で止まっている
	var stop_target := INF
	var standoff := -1.0
	var hiyari_ids := {}
	var cause := {}
	var pulse := 0.0
	var look := 0
	var role := 1
	var bike := false
	var vmax := 4.0
	var accel := 4.0
	var body_len := 0.8
	var body_wid := 0.42
	var bubble_ready_at := 0.0
	var has_bubble := false
	var forced_flag := false
	var queue_orderly := false   # 赤信号待ちの車の後ろに並んでいる（秩序ある待ち）
	var done := false

	func length() -> float:
		return (pts.size() - 1) * Geo.SAMPLE

	func point_at(ss: float) -> Vector2:
		var f := clampf(ss / Geo.SAMPLE, 0.0, pts.size() - 1.001)
		var i := int(f)
		return pts[i].lerp(pts[i + 1], f - i)

class Ped:
	var id: int
	var kind := 1
	var pts: PackedVector2Array
	var seg := 0
	var u := 0.0
	var cross := {}            # 区間番号 -> {a, b, sig, arm}
	var crossing := false
	var cross_b := Vector2.ZERO
	var pos := Vector2.ZERO
	var dir := Vector2.RIGHT
	var d := 0.0
	var t_alive := 0.0
	var expected := 1.0
	var waiting := false
	var wait_t := 0.0
	var wait_signal := false
	var blocked_t := 0.0
	var forced := false
	var dest := 0              # 目的地のセル番号
	var replan := false
	var cause := {}
	var pulse := 0.0
	var role := 1
	var look := 0
	var bubble_ready_at := 0.0
	var has_bubble := false
	var done := false

# ---------------------------------------------------------------------
# 状態
# ---------------------------------------------------------------------
var cars: Array = []
var peds: Array = []
var clock_s := 0.0
var funds := Tuning.START_FUNDS
var gauge := 0.0
var hiyari_total := 0
var max_gauge := 0.0
var over_limit_game_s := 0.0
var fail_reached := false
var cross_jay := 0
var cross_walk := 0
var forced_moves := 0
var max_stop_s := 0.0             # どの車も、止まり続けた最長の時間（シム秒）
var trips_done := 0
var car_delay_sum := 0.0          # 到着した車の、期待所要時間からの遅れの合計（試験用）
var car_stops_sum := 0.0          # 到着した車が止まっていた時間の合計（試験用）
var car_done_n := 0
var events: Array = []
var last_loop := {}
var loop_count := 0
var loop_start_h := Tuning.T_LOOP_START
var loop_end_h := Tuning.T_LOOP_END
var heat := {}
var waves: Array = []
var seed_base := Tuning.T_SEED
var use_schedule := true          # 試験用: 予定表を使うか
var through_scale := 1.0          # 試験用: 通過交通の量の倍率
var auto_loop := true             # 試験用: 1日が終わったら最初から繰り返す（画面では false）
var day_over := false
var fail_clock := -1.0            # 失敗に達した時刻（時）
var fail_pos := Vector2.ZERO      # そのときの、いちばん待ちがたまっていた場所
var bubbles: Array = []           # 不満バブル {id, agent, age, life, auto_at}
var bubble_stats := {"spawned": 0, "collected": 0, "missed": 0}
var income_log: Array = []        # 収入の記録 [時刻(時), 開発ポイント]
var decisions := 0                # 設置・間隔変更・取り壊しの回数
var auto_collect := true          # 暫定: バブルを自動で回収する（第2回でタップに置き換える）
var _bubble_acc := 0.0
var _bubble_id := 1
var _since_collect := 0.0
var _bub_rng := RandomNumberGenerator.new()
var linking := true               # 自動連動（試験で比べるためのスイッチ）

# 信号
var signals := {}                 # id -> {id, kind(0=交差点,1=路上), j, line, t, pos, preset, shift, order}
var junction_sig := [-1, -1, -1, -1]
var links: Array = []             # [{a, b, line}]
var sig_clock := 0.0
var fav_dir := [1, 1, 1, 1]       # 道路ごとの、車の多い向き（予定表から決める）
var _next_sig := 1
var _order := 0

var _next_id := 1
var _held := [0, 0, 0, 0]         # 交差点ごとの、使用中の区画（ビット）
var _hash := {}
var _crossers: Array = []
var _spawn_rng := RandomNumberGenerator.new()
var _route_rng := RandomNumberGenerator.new()
var _misc_rng := RandomNumberGenerator.new()
var _look_rng := RandomNumberGenerator.new()
var _through_car_acc := 0.0
var _through_ped_acc := 0.0
var _schedule: Array = []
var _sched_i := 0
var _pending: Array = []
var _route_cache := {}
var _graph: Dictionary
var _adj := {}
var _radj := {}
var _edge_cells: Array = []
var _fields := {}                 # 目的地のセル番号 -> {dist, dirty}
var _xrow := {}                   # 信号のある横断歩道の道路セル -> {sig, arm}
var _field_budget := 2

func _init() -> void:
	_graph = TownMap.build_walk_graph()
	_adj = _graph.adj
	_radj = _graph.radj
	_edge_cells = TownMap.edge_cells()
	_build_schedule()
	reset_loop()

func reset_loop() -> void:
	cars.clear()
	peds.clear()
	events.clear()
	_pending.clear()
	clock_s = loop_start_h * 3600.0
	gauge = 0.0
	max_gauge = 0.0
	hiyari_total = 0
	over_limit_game_s = 0.0
	fail_reached = false
	cross_jay = 0
	cross_walk = 0
	forced_moves = 0
	max_stop_s = 0.0
	trips_done = 0
	car_delay_sum = 0.0
	car_stops_sum = 0.0
	car_done_n = 0
	heat.clear()
	waves.clear()
	_held = [0, 0, 0, 0]
	day_over = false
	fail_clock = -1.0
	bubbles.clear()
	bubble_stats = {"spawned": 0, "collected": 0, "missed": 0}
	income_log.clear()
	_bubble_acc = 0.0
	_since_collect = 0.0
	_through_car_acc = 0.0
	_through_ped_acc = 0.0
	_sched_i = 0
	while _sched_i < _schedule.size() and _schedule[_sched_i].t < clock_s:
		_sched_i += 1
	# 通過交通だけ、ループごとに少し変わる
	_spawn_rng.seed = seed_base + loop_count * 7919
	_route_rng.seed = seed_base + 7
	_misc_rng.seed = seed_base + 99
	_look_rng.seed = seed_base + 555
	_bub_rng.seed = seed_base + 4321

func clock_hours() -> float:
	return clock_s / 3600.0

## 一日の中の時刻（0〜24）。1日は 6:00 → 翌6:00 なので、30時間目盛りを24で割った余り
func hour_of_day() -> float:
	return fposmod(clock_s / 3600.0, 24.0)

# ---------------------------------------------------------------------
# 予定表（建物から出る人。毎回同じ）
# ---------------------------------------------------------------------
func _sample_time(rng: RandomNumberGenerator, win: Array) -> float:
	# 山なりの分布（2つの一様乱数の平均）
	var u := 0.5 * (rng.randf() + rng.randf())
	return lerpf(win[0], win[1], u) * 3600.0

func _building_ids(type: String) -> Array:
	var out: Array = []
	for i in TownMap.BUILDINGS.size():
		if TownMap.BUILDINGS[i].type == type:
			out.append(i)
	return out

func _bdist(a: int, b: int) -> float:
	var da: Vector2 = TownMap.BUILDINGS[a].door
	var db: Vector2 = TownMap.BUILDINGS[b].door
	return absf(da.x - db.x) + absf(da.y - db.y)

func _build_schedule() -> void:
	_schedule.clear()
	var homes := _building_ids("home")
	var offices := _building_ids("office")
	var schools := _building_ids("school")
	var shops := _building_ids("shop")
	var rng := RandomNumberGenerator.new()
	for h in homes:
		rng.seed = Tuning.T_SEED + h * 131
		var office: int = offices[0]
		var school: int = schools[0]
		# 通勤者（朝は家→オフィス、夕は逆）。手段は距離で決まる（遠いほど車が多い）。車でない人の一部は自転車
		var share := clampf((_bdist(h, office) - Tuning.T_CAR_DIST_MIN) / Tuning.T_CAR_DIST_SPAN, Tuning.T_CAR_SHARE_MIN, Tuning.T_CAR_SHARE_MAX)
		for i in Tuning.T_COMMUTERS.get(h, 5):
			var mode := _pick_mode(rng, share)
			_add_trip(_sample_time(rng, Tuning.T_COMMUTE_MORNING), mode, SimWorld.ROLE_COMMUTER, h, office)
			_add_trip(_sample_time(rng, Tuning.T_COMMUTE_EVENING), mode, SimWorld.ROLE_COMMUTER, office, h)
		# 児童（徒歩。朝は家→学校、午後は逆）
		for i in Tuning.T_CHILDREN.get(h, 12):
			_add_trip(_sample_time(rng, Tuning.T_SCHOOL_GO), 0, SimWorld.ROLE_CHILD, h, school)
			_add_trip(_sample_time(rng, Tuning.T_SCHOOL_BACK), 0, SimWorld.ROLE_CHILD, school, h)
		# 買い物客（昼。遠い商店には車か自転車）
		for i in Tuning.T_SHOPPERS_PER_HOME:
			var shop: int = shops[rng.randi_range(0, shops.size() - 1)]
			var far := _bdist(h, shop) > 14.0
			var mode2 := _pick_mode(rng, 0.45 if far else 0.0)
			_add_trip(rng.randf_range(Tuning.T_SHOP_GO[0], Tuning.T_SHOP_GO[1]) * 3600.0, mode2, SimWorld.ROLE_SHOPPER, h, shop)
			_add_trip(rng.randf_range(Tuning.T_SHOP_BACK[0], Tuning.T_SHOP_BACK[1]) * 3600.0, mode2, SimWorld.ROLE_SHOPPER, shop, h)
	# 通過交通（固定の予定表。量だけ、ループごとに少し間引く）。発生率は「シム秒あたり」
	var trng := RandomNumberGenerator.new()
	trng.seed = Tuning.T_SEED + 999
	var acc_c := 0.0
	var acc_p := 0.0
	var dts := 0.5
	var day_s := (Tuning.T_LOOP_END - Tuning.T_LOOP_START) * 3600.0 / Tuning.CLOCK_RATE
	var tau := 0.0
	while tau < day_s:
		var game_s := Tuning.T_LOOP_START * 3600.0 + tau * Tuning.CLOCK_RATE
		var hh := game_s / 3600.0
		acc_c += _rate_at(hh, Tuning.T_THROUGH_CAR_BASE, Tuning.T_THROUGH_CAR_PEAK, Tuning.T_THROUGH_CAR_NIGHT) * dts
		acc_p += _rate_at(hh, Tuning.T_THROUGH_PED_BASE, Tuning.T_THROUGH_PED_PEAK, 0.0) * dts
		while acc_c >= 1.0:
			acc_c -= 1.0
			var a := _pick_edge_rng(trng, -1)
			var b := _pick_edge_rng(trng, a)
			_schedule.append({"t": game_s, "mode": 1, "role": SimWorld.ROLE_COMMUTER, "src": 100 + a, "dst": 100 + b, "tries": 0, "through": true})
		while acc_p >= 1.0:
			acc_p -= 1.0
			var n := _edge_cells.size()
			var a2 := trng.randi_range(0, n - 1)
			var b2 := (a2 + trng.randi_range(1, n - 1)) % n
			_schedule.append({"t": game_s, "mode": 0, "role": SimWorld.ROLE_COMMUTER, "src": 200 + a2, "dst": 200 + b2, "tries": 0, "through": true})
		tau += dts
	_schedule.sort_custom(func(a, b): return a.t < b.t)
	# 道路ごとに、車の多い向きを決める（連動の向きに使う）
	var tally := [[0.0, 0.0], [0.0, 0.0], [0.0, 0.0], [0.0, 0.0]]
	for tr in _schedule:
		if tr.mode != 1:
			continue
		if tr.t < Tuning.T_FAV_WINDOW[0] * 3600.0 or tr.t > Tuning.T_FAV_WINDOW[1] * 3600.0:
			continue
		var r := _route_for(tr.src, tr.dst)
		if r.is_empty():
			continue
		for pc in r.pieces:
			var sgn := 1 if pc.c1 > pc.c0 else 0
			tally[pc.l][sgn] += absf(pc.c1 - pc.c0)
	for l in 4:
		fav_dir[l] = 1 if tally[l][1] >= tally[l][0] else -1

## 手段: 0=徒歩 1=車 2=自転車
func _pick_mode(rng: RandomNumberGenerator, car_share: float) -> int:
	var r := rng.randf()
	if r < car_share:
		return 1
	return 2 if rng.randf() < Tuning.T_BIKE_SHARE else 0

func _add_trip(t: float, mode: int, role: int, src: int, dst: int) -> void:
	_schedule.append({"t": t, "mode": mode, "role": role, "src": src, "dst": dst, "tries": 0})

# ---------------------------------------------------------------------
# 車の経路
# ---------------------------------------------------------------------
## 車の出入口: 建物（0〜8）または地図の端（100〜107）
func _car_point(ref: int) -> Array:
	if ref >= 100:
		var e := ref - 100
		var l := e / 2
		var t := -(TownMap.EXT - 0.5) if e % 2 == 0 else (TownMap.EXT - 0.5)
		return [l, t]
	var b: Dictionary = TownMap.BUILDINGS[ref]
	return [b.line, b.t]

func _route_for(src: int, dst: int) -> Dictionary:
	var key := "%d>%d" % [src, dst]
	if _route_cache.has(key):
		return _route_cache[key]
	var sp := _car_point(src)
	var dp := _car_point(dst)
	var r := _make_route(sp[0], sp[1], dp[0], dp[1])
	_route_cache[key] = r
	return r

func _make_route(sl: int, st: float, dl: int, dt: float) -> Dictionary:
	var plan := TownMap.plan_route(sl, st, dl, dt)
	if plan.is_empty():
		return {}
	var poly := PackedVector2Array()
	var jc: Array = []
	var pieces: Array = []
	var acc := 0.0
	var hd: int = plan.hd0
	var cur_line := sl
	var cur_coord := st
	poly.append(TownMap.lane_point(sl, st, hd))
	for ev in plan.events:
		var j: int = ev.j
		var center := TownMap.junction_center(j)
		var arm_in := TownMap.opposite(ev.hin)
		var arm_out: int = ev.hout
		var in_pt := center + Geo.inbound_point(arm_in, TownMap.ROAD_HALF)
		var lc_in := TownMap.line_coord(cur_line, center) - TownMap.sign_of(ev.hin) * TownMap.ROAD_HALF
		pieces.append({"l": cur_line, "c0": cur_coord, "c1": lc_in, "s0": acc})
		acc += poly[poly.size() - 1].distance_to(in_pt)
		poly.append(in_pt)
		var s_in := acc
		var curve := Geo.box_curve(arm_in, arm_out)
		var quads := 0
		for i in range(1, curve.size()):
			var q := center + curve[i]
			acc += poly[poly.size() - 1].distance_to(q)
			poly.append(q)
		# 通る区画は、経路を細かく刻んで全部数える（直進は点が2つしかなく、真ん中だけだと反対側の区画を見落とす）
		for q in Geo.resample(curve):
			quads |= Geo.quad_bit(q)
		jc.append({"j": j, "arm_in": arm_in, "s_box_in": s_in, "s_box_out": acc, "quads": quads,
			"s_stop": s_in - (Tuning.STOP_LINE_R - TownMap.ROAD_HALF) - Tuning.CAR_LENGTH * 0.5,
			"s_req": s_in - 0.05 - Tuning.CAR_LENGTH * 0.5, "state": 0})
		hd = arm_out
		cur_line = TownMap.line_of_hd(j, hd)
		cur_coord = TownMap.line_coord(cur_line, center) + TownMap.sign_of(hd) * TownMap.ROAD_HALF
	var end_pt := TownMap.lane_point(dl, dt, plan.hd_end)
	pieces.append({"l": cur_line, "c0": cur_coord, "c1": dt, "s0": acc})
	acc += poly[poly.size() - 1].distance_to(end_pt)
	poly.append(end_pt)
	return {"pts": Geo.resample(poly), "jc": jc, "pieces": pieces, "length": acc}

# ---------------------------------------------------------------------
# 信号
# ---------------------------------------------------------------------
func _cycle(preset: int) -> float:
	return 2.0 * (Tuning.SIGNAL_GREEN[preset] + Tuning.SIGNAL_YELLOW + Tuning.SIGNAL_ALL_RED)

func _local_t(sg: Dictionary) -> float:
	return fposmod(sig_clock - sg.shift, _cycle(sg.preset))

## 車の信号（交差点）: 0=青 1=黄 2=赤。arm は車が来る側の腕
func junction_light(sg: Dictionary, arm: int) -> int:
	var g: float = Tuning.SIGNAL_GREEN[sg.preset]
	var h: float = g + Tuning.SIGNAL_YELLOW + Tuning.SIGNAL_ALL_RED
	var u := _local_t(sg) - (0.0 if arm <= 1 else h)
	if u >= 0.0 and u < g:
		return 0
	if u >= g and u < g + Tuning.SIGNAL_YELLOW:
		return 1
	return 2

## 歩行者の信号（交差点の腕 arm を渡る）。青の残り秒数。赤なら -1
func junction_ped_left(sg: Dictionary, arm: int) -> float:
	var g: float = Tuning.SIGNAL_GREEN[sg.preset]
	var h: float = g + Tuning.SIGNAL_YELLOW + Tuning.SIGNAL_ALL_RED
	var perp := 1 if arm <= 1 else 0          # 渡る道路と直交する車の系統
	var u := _local_t(sg) - (0.0 if perp == 0 else h)
	if u >= 0.0 and u < g:
		return g - u
	return -1.0

func _xwalk_green_len(sg: Dictionary) -> float:
	var g: float = Tuning.SIGNAL_GREEN[sg.preset]
	return _cycle(sg.preset) - g - Tuning.SIGNAL_YELLOW - 2.0 * Tuning.SIGNAL_ALL_RED

func xwalk_light(sg: Dictionary) -> int:
	var gc := _xwalk_green_len(sg)
	var t := _local_t(sg)
	if t < gc:
		return 0
	if t < gc + Tuning.SIGNAL_YELLOW:
		return 1
	return 2

func xwalk_ped_left(sg: Dictionary) -> float:
	var g: float = Tuning.SIGNAL_GREEN[sg.preset]
	var start := _xwalk_green_len(sg) + Tuning.SIGNAL_YELLOW + Tuning.SIGNAL_ALL_RED
	var t := _local_t(sg)
	if t >= start and t < start + g:
		return start + g - t
	return -1.0

## 表示用: 信号 sg の、腕 arm の車の灯・歩行者の灯
func car_light_of(sg: Dictionary, arm: int) -> int:
	return junction_light(sg, arm) if sg.kind == 0 else xwalk_light(sg)

func ped_left_of(sg: Dictionary, arm: int) -> float:
	return junction_ped_left(sg, arm) if sg.kind == 0 else xwalk_ped_left(sg)

# --- 置く場所 ---
## 画面でタップした地面の点から、信号を置ける場所を調べる
func placement_at(g: Vector2) -> Dictionary:
	if funds < Tuning.SIGNAL_COST:
		return {"ok": false, "reason": "funds"}
	# 交差点
	for j in 4:
		var c := TownMap.junction_center(j)
		if maxf(absf(g.x - c.x), absf(g.y - c.y)) < 3.6:
			if junction_sig[j] >= 0:
				return {"ok": false, "reason": "exists"}
			return {"ok": true, "kind": 0, "j": j, "pos": c}
	# 路上
	for l in TownMap.LINE_COUNT:
		var perp: float = absf((g.y if TownMap.line_axis(l) == 0 else g.x) - TownMap.line_c(l))
		if perp > 2.4:
			continue
		var t := floorf(TownMap.line_coord(l, g)) + 0.5
		if absf(t) > TownMap.EXT - 2.0:
			continue
		if absf(t - TownMap.ROADS[0]) < Tuning.T_XWALK_MIN_FROM_JUNCTION or absf(t - TownMap.ROADS[1]) < Tuning.T_XWALK_MIN_FROM_JUNCTION:
			return {"ok": false, "reason": "near_junction"}
		for id in signals:
			var sg: Dictionary = signals[id]
			if sg.kind == 1 and sg.line == l and absf(sg.t - t) < Tuning.T_XWALK_MIN_GAP:
				return {"ok": false, "reason": "near_signal"}
		return {"ok": true, "kind": 1, "line": l, "t": t, "pos": TownMap.line_point(l, t)}
	return {"ok": false, "reason": "no_road"}

func place_signal_at(pl: Dictionary, preset: int) -> bool:
	if not pl.get("ok", false) or funds < Tuning.SIGNAL_COST:
		return false
	funds -= Tuning.SIGNAL_COST
	decisions += 1
	var sg := {"id": _next_sig, "kind": pl.kind, "j": pl.get("j", -1), "line": pl.get("line", -1), "t": pl.get("t", 0.0),
		"pos": pl.pos, "preset": preset, "shift": sig_clock, "order": _order}
	_next_sig += 1
	_order += 1
	signals[sg.id] = sg
	if sg.kind == 0:
		junction_sig[sg.j] = sg.id
	waves.append({"c": sg.pos, "r": 0.0})
	_signals_changed()
	return true

func can_place() -> bool:
	return funds >= Tuning.SIGNAL_COST

func demolish(id: int) -> void:
	demolish_signal(id)

func set_preset(id: int, preset: int) -> void:
	set_signal_preset(id, preset)

func preset_of(id: int) -> int:
	return signals[id].preset if signals.has(id) else 1

func signal_at(g: Vector2) -> int:
	var best := -1
	var bd := 3.2
	for id in signals:
		var d: float = (signals[id].pos as Vector2).distance_to(g)
		if d < bd:
			bd = d
			best = id
	return best

func demolish_signal(id: int) -> void:
	if not signals.has(id):
		return
	var sg: Dictionary = signals[id]
	if sg.kind == 0:
		junction_sig[sg.j] = -1
	signals.erase(id)
	decisions += 1
	funds += int(Tuning.SIGNAL_COST * Tuning.DEMOLISH_REFUND_RATE)
	_signals_changed()

func set_signal_preset(id: int, preset: int) -> void:
	if signals.has(id) and signals[id].preset != preset:
		signals[id].preset = preset
		decisions += 1
		_signals_changed()

func _signals_changed() -> void:
	_relink()
	# 信号のある横断歩道の行
	_xrow.clear()
	for id in signals:
		var sg: Dictionary = signals[id]
		if sg.kind == 0:
			var rows := TownMap.junction_xrows(sg.j)
			for k in rows:
				_xrow[k] = {"sig": id, "arm": rows[k][1]}
		else:
			for k in TownMap.line_xrows(sg.line, sg.t):
				_xrow[k] = {"sig": id, "arm": -1}
	for dest in _fields:
		_fields[dest].dirty = true
	for p in peds:
		p.replan = true

# --- 自動連動 ---
func _sig_lines(sg: Dictionary) -> Array:
	return [sg.j % 2, 2 + sg.j / 2] if sg.kind == 0 else [sg.line]

func _sig_coord(sg: Dictionary, l: int) -> float:
	if sg.kind == 0:
		return TownMap.line_coord(l, TownMap.junction_center(sg.j))
	return sg.t

func _green_start(sg: Dictionary, l: int) -> float:
	# 道路 l の車が青になる、信号内の時刻。縦道（交差点の B 系統）は半周期あと
	if sg.kind == 0 and TownMap.line_axis(l) == 1:
		var g: float = Tuning.SIGNAL_GREEN[sg.preset]
		return g + Tuning.SIGNAL_YELLOW + Tuning.SIGNAL_ALL_RED
	return 0.0

func _relink() -> void:
	links.clear()
	if not linking:
		return
	var ids := signals.keys()
	ids.sort_custom(func(a, b): return signals[a].order < signals[b].order)
	# つながる組
	var nb := {}
	for id in ids:
		nb[id] = []
	for i in ids.size():
		for k in range(i + 1, ids.size()):
			var a: Dictionary = signals[ids[i]]
			var b: Dictionary = signals[ids[k]]
			if a.preset != b.preset:
				continue
			for l in _sig_lines(a):
				if not (l in _sig_lines(b)):
					continue
				var dist := absf(_sig_coord(a, l) - _sig_coord(b, l))
				if dist > 0.01 and dist <= Tuning.T_LINK_DIST:
					nb[a.id].append([b.id, l])
					nb[b.id].append([a.id, l])
					links.append({"a": a.id, "b": b.id, "line": l})
	# 先に置いた信号を根にして、青のずれを決める（根は今のまま）
	var seen := {}
	for id in ids:
		if seen.has(id):
			continue
		seen[id] = true
		var queue: Array = [id]
		while not queue.is_empty():
			var cur: Dictionary = signals[queue.pop_front()]
			for e in nb[cur.id]:
				if seen.has(e[0]):
					continue
				seen[e[0]] = true
				var n: Dictionary = signals[e[0]]
				var l: int = e[1]
				var tt := absf(_sig_coord(cur, l) - _sig_coord(n, l)) / Tuning.T_WAVE_SPEED
				var downstream: bool = (_sig_coord(n, l) - _sig_coord(cur, l)) * fav_dir[l] > 0.0
				var abs_start: float = cur.shift + _green_start(cur, l) + (tt if downstream else -tt)
				n.shift = fposmod(abs_start - _green_start(n, l), _cycle(n.preset))
				queue.append(n.id)

## その信号が、ほかの信号とつながっているか（表示用）
func is_linked(id: int) -> bool:
	for lk in links:
		if lk.a == id or lk.b == id:
			return true
	return false

# ---------------------------------------------------------------------
# メインループ
# ---------------------------------------------------------------------
## dt = シム秒（速度設定で伸び縮みする）、real_dt = 実時間の秒（バブルの寿命に使う。速度設定に連動しない）
func step(dt: float, real_dt := -1.0) -> void:
	var rdt := real_dt if real_dt >= 0.0 else dt
	clock_s += dt * Tuning.CLOCK_RATE
	sig_clock += dt
	_field_budget = 2
	_spawn(dt)
	_build_hash()
	_update_fields()
	_step_cars(dt)
	_step_peds(dt)
	_update_discontent(dt)
	_update_heat_and_waves(dt)
	_update_bubbles(rdt)
	_cleanup()
	for e in events:
		e.t += dt
	events = events.filter(func(e): return e.t < 1.5)
	if fail_reached and fail_clock < 0.0:
		fail_clock = clock_hours()
		var best_v := -1.0
		for key in heat:
			if heat[key] > best_v:
				best_v = heat[key]
				fail_pos = Vector2(key.x + 0.5, key.y + 0.5)
	if clock_hours() >= loop_end_h:
		last_loop = {"max_gauge": max_gauge, "hiyari": hiyari_total, "cross_jay": cross_jay,
			"cross_walk": cross_walk, "signal": not signals.is_empty(), "fail": fail_reached,
			"forced": forced_moves, "max_stop": max_stop_s, "trips": trips_done,
			"car_delay": car_delay_sum / maxf(car_done_n, 1), "car_stop": car_stops_sum / maxf(car_done_n, 1), "car_n": car_done_n}
		loop_count += 1
		if auto_loop:
			reset_loop()
		else:
			day_over = true
			clock_s = loop_end_h * 3600.0

## 同じステージを、最初からやり直す（開発ポイントも信号も初期状態。速度設定は main が持つので変わらない）
func restart() -> void:
	signals.clear()
	for i in 4:
		junction_sig[i] = -1
	links.clear()
	_xrow.clear()
	for dest in _fields:
		_fields[dest].dirty = true
	funds = Tuning.START_FUNDS
	decisions = 0
	sig_clock = 0.0
	loop_count = 0
	reset_loop()

# ---------------------------------------------------------------------
# 発生
# ---------------------------------------------------------------------
## 時刻 h（時）の発生率（1/シム秒）: 朝と夕の山に加えて、夜の山（night）
func _rate_at(h: float, base: float, peak: float, night: float) -> float:
	var x := (h - 7.9) / 0.7
	var x2 := (h - 17.8) / 0.8
	var x3 := (h - Tuning.T_NIGHT_PEAK_H) / Tuning.T_NIGHT_PEAK_W
	return base + peak * (exp(-x * x) + 0.8 * exp(-x2 * x2)) + night * exp(-x3 * x3)

func _spawn(dt: float) -> void:
	# 予定表（建物から出る人）
	while use_schedule and _sched_i < _schedule.size() and _schedule[_sched_i].t <= clock_s:
		_pending.append(_schedule[_sched_i])
		_sched_i += 1
	var still: Array = []
	for tr in _pending:
		if tr.get("through", false) and tr.tries == 0 and _spawn_rng.randf() < Tuning.T_THROUGH_SKIP:
			continue            # 通過交通の量だけ、ループごとに少し変わる
		if not _spawn_trip(tr.mode, tr.role, tr.src, tr.dst):
			tr.tries += 1
			if tr.tries < 600:
				still.append(tr)
	_pending = still

## 通過交通の入口（重みつき）。exclude は選ばない入口（出口は入口と別にする）
func _pick_edge_rng(rng: RandomNumberGenerator, exclude: int) -> int:
	var total := 0.0
	for e in 8:
		if e != exclude:
			total += Tuning.T_EDGE_WEIGHT[e]
	var r := rng.randf() * total
	for e in 8:
		if e == exclude:
			continue
		r -= Tuning.T_EDGE_WEIGHT[e]
		if r <= 0.0:
			return e
	return 7 if exclude != 7 else 6

func _spawn_trip(mode: int, role: int, src: int, dst: int) -> bool:
	if mode != 0:
		return _spawn_car(src, dst, role, mode == 2)
	if src >= 200:
		return _spawn_ped_cells(TownMap.cell_index(_edge_cells[src - 200]), TownMap.cell_index(_edge_cells[dst - 200]), role)
	var sc: Vector2i = TownMap.cell_of(TownMap.BUILDINGS[src].door)
	var dc: Vector2i = TownMap.cell_of(TownMap.BUILDINGS[dst].door)
	return _spawn_ped_cells(TownMap.cell_index(sc), TownMap.cell_index(dc), role)

func _spawn_car(src: int, dst: int, role: int, bike := false) -> bool:
	var r := _route_for(src, dst)
	if r.is_empty():
		return true
	var start: Vector2 = r.pts[0]
	for c in cars:
		if c.pos.distance_to(start) < Tuning.CAR_LENGTH + Tuning.CAR_GAP_CAR + 0.2:
			return false
	for q in peds:
		if q.crossing and Geo.seg_dist(start, q.pos, q.cross_b) < Tuning.CAR_LENGTH + 0.3:
			return false
	var c := Car.new()
	c.id = _next_id
	_next_id += 1
	c.pts = r.pts
	c.jc = (r.jc as Array).duplicate(true)
	c.pieces = r.pieces
	c.expected = r.length / Tuning.CAR_SPEED
	c.pos = start
	c.dir = (c.pts[1] - c.pts[0]).normalized()
	c.look = _look_rng.randi()
	c.role = role
	c.bike = bike
	c.vmax = Tuning.BIKE_SPEED if bike else Tuning.CAR_SPEED
	c.accel = Tuning.BIKE_ACCEL if bike else Tuning.CAR_ACCEL
	c.body_len = Tuning.BIKE_LENGTH if bike else Tuning.CAR_LENGTH
	c.body_wid = Tuning.BIKE_WIDTH if bike else Tuning.CAR_WIDTH
	if bike:
		c.expected = r.length / Tuning.BIKE_SPEED
	cars.append(c)
	return true

# ---------------------------------------------------------------------
# 歩行者の経路（目的地ごとの距離場）
# ---------------------------------------------------------------------
func _field_for(dest: int) -> Dictionary:
	if not _fields.has(dest):
		_fields[dest] = {"dist": PackedFloat32Array(), "dirty": true}
	return _fields[dest]

func _update_fields() -> void:
	# 信号が変わったあと、使われている目的地の距離場を1ステップに2つまで作り直す
	for dest in _fields:
		if _field_budget <= 0:
			break
		var f: Dictionary = _fields[dest]
		if f.dirty:
			f.dist = _compute_field(dest)
			f.dirty = false
			_field_budget -= 1

func _compute_field(dest: int) -> PackedFloat32Array:
	var dist := PackedFloat32Array()
	dist.resize(TownMap.N * TownMap.N)
	dist.fill(INF)
	var hk := PackedFloat32Array()
	var hv := PackedInt32Array()
	dist[dest] = 0.0
	_heap_push(hk, hv, 0.0, dest)
	while hk.size() > 0:
		var top := _heap_pop(hk, hv)
		var d: float = top[0]
		var v: int = top[1]
		if d > dist[v]:
			continue
		if not _radj.has(v):
			continue
		for pr in _radj[v]:
			var u: int = pr[0]
			var w := 1.0
			if pr[1] == 1 and not _xrow.has(pr[2]):
				w += Tuning.PED_DETOUR_MAX
			var nd := d + w
			if nd < dist[u]:
				dist[u] = nd
				_heap_push(hk, hv, nd, u)
	return dist

func _heap_push(hk: PackedFloat32Array, hv: PackedInt32Array, k: float, v: int) -> void:
	hk.append(k)
	hv.append(v)
	var i := hk.size() - 1
	while i > 0:
		var p := (i - 1) / 2
		if hk[p] <= hk[i]:
			break
		var tk := hk[p]
		hk[p] = hk[i]
		hk[i] = tk
		var tv := hv[p]
		hv[p] = hv[i]
		hv[i] = tv
		i = p

func _heap_pop(hk: PackedFloat32Array, hv: PackedInt32Array) -> Array:
	var rk := hk[0]
	var rv := hv[0]
	var last := hk.size() - 1
	hk[0] = hk[last]
	hv[0] = hv[last]
	hk.resize(last)
	hv.resize(last)
	var i := 0
	var n := hk.size()
	while true:
		var l := 2 * i + 1
		var r := l + 1
		var m := i
		if l < n and hk[l] < hk[m]:
			m = l
		if r < n and hk[r] < hk[m]:
			m = r
		if m == i:
			break
		var tk := hk[m]
		hk[m] = hk[i]
		hk[i] = tk
		var tv := hv[m]
		hv[m] = hv[i]
		hv[i] = tv
		i = m
	return [rk, rv]

## 距離場をたどって、セルの列を作る（同じ費用の道はランダムに選ぶ → 渡る場所がばらける）
func _path_cells(start: int, dest: int, dist: PackedFloat32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	var cur := start
	out.append(cur)
	var guard := 0
	while cur != dest and guard < 600:
		guard += 1
		if not _adj.has(cur):
			break
		var best := INF
		var cands: Array = []
		for e in _adj[cur]:
			var v: int = e[0]
			var w := 1.0
			if e[1] == 1 and not _xrow.has(e[2]):
				w += Tuning.PED_DETOUR_MAX
			var val: float = w + dist[v]
			if val < best - 0.001:
				best = val
				cands = [v]
			elif absf(val - best) <= 0.001:
				cands.append(v)
		if cands.is_empty() or best >= INF:
			break
		cur = cands[_route_rng.randi_range(0, cands.size() - 1)]
		out.append(cur)
	return out

func _cell_vec(idx: int) -> Vector2i:
	return Vector2i(idx % TownMap.N, idx / TownMap.N)

## セルの列 → 折れ線と、道路を渡る区間
func _build_ped_path(cells: PackedInt32Array, first_pos: Variant = null) -> Dictionary:
	var n := cells.size()
	var kinds: Array = []
	for i in n:
		kinds.append(TownMap.kind_at(_cell_vec(cells[i])))
	var keep: Array = []
	keep.resize(n)
	keep.fill(false)
	keep[0] = true
	keep[n - 1] = true
	var legs: Array = []          # [start_i, end_i]
	var i := 0
	while i < n - 1:
		if kinds[i] == TownMap.K_SIDE and kinds[i + 1] != TownMap.K_SIDE:
			var m := i + 1
			while m < n and kinds[m] != TownMap.K_SIDE:
				m += 1
			if m < n:
				legs.append([i, m])
				keep[i] = true
				keep[m] = true
				i = m
				continue
		i += 1
	for k in range(1, n - 1):
		var a := _cell_vec(cells[k]) - _cell_vec(cells[k - 1])
		var b := _cell_vec(cells[k + 1]) - _cell_vec(cells[k])
		if a != b:
			keep[k] = true
	var pts := PackedVector2Array()
	var index_of := {}
	if first_pos != null:
		pts.append(first_pos)
	for k in n:
		if keep[k]:
			index_of[k] = pts.size()
			pts.append(TownMap.cell_center(_cell_vec(cells[k])))
	var cross := {}
	for lg in legs:
		var info = _xrow.get(cells[lg[0] + 1], null)
		cross[index_of[lg[0]]] = {
			"a": TownMap.cell_center(_cell_vec(cells[lg[0]])),
			"b": TownMap.cell_center(_cell_vec(cells[lg[1]])),
			"sig": info.sig if info != null else -1,
			"arm": info.arm if info != null else -1}
	return {"pts": pts, "cross": cross}

func _pick_role_for(src_role: int) -> int:
	return src_role

func _spawn_ped_cells(start: int, dest: int, role: int) -> bool:
	var f := _field_for(dest)
	if f.dirty:
		f.dist = _compute_field(dest)
		f.dirty = false
	var cells := _path_cells(start, dest, f.dist)
	if cells[cells.size() - 1] != dest:
		return true
	var built := _build_ped_path(cells)
	var p := Ped.new()
	p.id = _next_id
	_next_id += 1
	p.pts = built.pts
	p.cross = built.cross
	p.dest = dest
	p.role = role
	p.look = _look_rng.randi()
	var sv := _cell_vec(start)
	var dv := _cell_vec(dest)
	p.expected = (absf(sv.x - dv.x) + absf(sv.y - dv.y)) * 1.1 / Tuning.PED_SPEED
	p.pos = p.pts[0]
	if p.pts.size() > 1:
		p.dir = (p.pts[1] - p.pts[0]).normalized()
	peds.append(p)
	return true

## 信号が変わったあと、まだ道路を渡り始めていない歩行者の経路を引き直す
func _replan_ped(p: Ped) -> void:
	var f := _field_for(p.dest)
	if f.dirty:
		return          # 距離場の作り直しを待つ
	var start := TownMap.cell_index(TownMap.cell_of(p.pos))
	if TownMap.kind_at(_cell_vec(start)) != TownMap.K_SIDE:
		p.replan = false
		return
	var cells := _path_cells(start, p.dest, f.dist)
	if cells[cells.size() - 1] != p.dest:
		p.replan = false
		return
	var cpos := TownMap.cell_center(_cell_vec(start))
	var built := _build_ped_path(cells, p.pos if p.pos.distance_to(cpos) > 0.02 else null)
	p.pts = built.pts
	p.cross = built.cross
	p.seg = 0
	p.u = 0.0
	p.replan = false

# ---------------------------------------------------------------------
# 空間ハッシュ
# ---------------------------------------------------------------------
func _cell(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x), floori(p.y))

func _build_hash() -> void:
	_hash.clear()
	_crossers = peds.filter(func(q): return q.crossing)
	for c in cars:
		var k := _cell(c.pos)
		if not _hash.has(k):
			_hash[k] = []
		_hash[k].append(c)
	for p in peds:
		var k := _cell(p.pos)
		if not _hash.has(k):
			_hash[k] = []
		_hash[k].append(p)

func _near(p: Vector2) -> Array:
	var out: Array = []
	var c := _cell(p)
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var k := Vector2i(c.x + dx, c.y + dy)
			if _hash.has(k):
				out.append_array(_hash[k])
	return out

# ---------------------------------------------------------------------
# 車
# ---------------------------------------------------------------------
func _scan_ahead(c: Car) -> Array:
	var look := Tuning.CAR_LOOKAHEAD + c.v * c.v / (2.0 * Tuning.CAR_DECEL_COMFORT)
	var n := c.pts.size()
	var i0 := int(c.s / Geo.SAMPLE) + 1
	var i1 := mini(n - 1, int((c.s + look) / Geo.SAMPLE) + 1)
	var near_cross: Array = []
	for q in _crossers:
		if q.pos.distance_to(c.pos) < look + 4.0:
			near_cross.append(q)
	for i in range(i0, i1 + 1):
		var p := c.pts[i]
		for q in near_cross:
			if Geo.seg_dist(p, q.pos, q.cross_b) < Tuning.CAR_DETECT_R_PED:
				return [i * Geo.SAMPLE - c.s - Tuning.CAR_GAP_PED, q]
		if (i - i0) % 2 != 0:
			continue
		for o in _near(p):
			if o == c or o.kind != KIND_CAR:
				continue
			if p.distance_to(o.pos) < Tuning.CAR_DETECT_R:
				return [i * Geo.SAMPLE - c.s - Tuning.CAR_GAP_CAR, o]
	return [INF, null]

func _exit_clear(c: Car, e: Dictionary) -> bool:
	var i0 := int(e.s_box_out / Geo.SAMPLE)
	var i1 := mini(c.pts.size() - 1, int((e.s_box_out + Tuning.CAR_LENGTH + 0.4) / Geo.SAMPLE))
	for i in range(i0, i1 + 1, 2):
		for o in _near(c.pts[i]):
			if o != c and o.kind == KIND_CAR and c.pts[i].distance_to(o.pos) < Tuning.CAR_DETECT_R:
				return false
	return true

## 路上の信号（横断歩道）で止まるべき位置。なければ INF
func _xwalk_target(c: Car) -> float:
	var best := INF
	var stop_d: float = c.v * c.v / (2.0 * Tuning.CAR_DECEL_COMFORT)
	for id in signals:
		var sg: Dictionary = signals[id]
		if sg.kind != 1:
			continue
		for pc in c.pieces:
			if pc.l != sg.line:
				continue
			var lo := minf(pc.c0, pc.c1)
			var hi := maxf(pc.c0, pc.c1)
			if sg.t < lo or sg.t > hi:
				continue
			var s_q: float = pc.s0 + absf(sg.t - pc.c0)
			var s_stop: float = s_q - 0.5 - 0.25 - Tuning.CAR_LENGTH * 0.5
			if c.s > s_stop + 0.35 or s_stop - c.s > 14.0:
				continue
			var light := xwalk_light(sg)
			var to_line := s_stop - c.s
			if light == 2 or (light == 1 and to_line > stop_d):
				best = minf(best, s_stop)
	return best

func _step_cars(dt: float) -> void:
	# 1) 交差点の区画の解放と、次の交差点への切り替え
	for c in cars:
		while c.ji < c.jc.size():
			var e: Dictionary = c.jc[c.ji]
			if e.state == 1 and c.s - Tuning.CAR_LENGTH * 0.5 > e.s_box_out:
				_held[e.j] &= ~e.quads
				e.state = 2
			if e.state == 2:
				c.ji += 1
				continue
			break
	# 2) 進入要求と許可
	var req := {}
	for c in cars:
		c.stop_target = INF
		c.at_red = false
		if c.ji >= c.jc.size():
			continue
		var e: Dictionary = c.jc[c.ji]
		if e.state != 0:
			continue
		var sid: int = junction_sig[e.j]
		var committed := false
		if sid >= 0:
			committed = c.s > e.s_stop + 0.05
			if not committed:
				var light := junction_light(signals[sid], e.arm_in)
				var to_line: float = e.s_stop - c.s
				if light == 2 or (light == 1 and to_line > c.v * c.v / (2.0 * Tuning.CAR_DECEL_COMFORT)):
					c.stop_target = e.s_stop
					c.at_red = true
					continue
		c.stop_target = e.s_req
		var dist: float = e.s_req - c.s
		if not (dist < c.v * c.v / (2.0 * Tuning.CAR_DECEL_COMFORT) + 0.6):
			continue
		# 先頭の車だけが要求できる
		var sc0: Array = _scan_ahead(c)
		if sc0[1] != null and sc0[1].kind == KIND_CAR and sc0[0] < dist + 0.2:
			continue
		if not req.has(e.j):
			req[e.j] = []
		req[e.j].append(c)
	for j in req:
		var lst: Array = req[j]
		var sid2: int = junction_sig[j]
		if sid2 < 0:
			# 信号なし: 交差する相手と鉢合わせると、互いにためらう
			for c in lst:
				if c.standoff < 0.0:
					var conflict := false
					for o in lst:
						if o != c and (o.jc[o.ji].quads & c.jc[c.ji].quads) != 0:
							conflict = true
							break
					c.standoff = _misc_rng.randf_range(Tuning.CAR_STANDOFF_MIN, Tuning.CAR_STANDOFF_MAX) if conflict else 0.0
				c.standoff -= dt
		for i in range(lst.size() - 1, 0, -1):
			var k := _misc_rng.randi_range(0, i)
			var tmp = lst[i]
			lst[i] = lst[k]
			lst[k] = tmp
		# 長く待った車を先にする（完全な詰まりを避ける）
		lst.sort_custom(func(a, b): return a.wait_t > b.wait_t if (a.wait_t > Tuning.T_BREAKER_WAIT or b.wait_t > Tuning.T_BREAKER_WAIT) else false)
		for c in lst:
			var e2: Dictionary = c.jc[c.ji]
			if sid2 < 0 and c.standoff > 0.0 and c.wait_t < Tuning.T_BREAKER_WAIT:
				continue
			if (_held[j] & e2.quads) != 0:
				continue
			if c.wait_t < Tuning.T_BREAKER_WAIT and not _exit_clear(c, e2):
				continue
			e2.state = 1
			_held[j] |= e2.quads
	# 3) 走行
	for c in cars:
		c.t_alive += dt
		var sc: Array = _scan_ahead(c)
		var free: float = sc[0]
		var obs = sc[1]
		# 安全弁: 交差点の中で15秒以上動けない車は、前の車を無視して進む（完全な詰まりを避ける。回数を記録）
		if c.ji < c.jc.size() and c.jc[c.ji].state == 1 and c.wait_t > 15.0 and obs != null and obs.kind == KIND_CAR:
			free = INF
			obs = null
			if not c.forced_flag:
				c.forced_flag = true
				forced_moves += 1
		var obstacle_bound := true
		var target: float = _xwalk_target(c)
		# 秩序ある待ち: 赤信号で止まっている車、またはその後ろに並んでいる車
		c.queue_orderly = obs != null and obs.kind == KIND_CAR and (obs.at_red or obs.queue_orderly)
		if target < INF and target - c.s < 5.0:
			c.at_red = true
		if c.ji < c.jc.size() and c.jc[c.ji].state == 0:
			target = minf(target, c.stop_target)
		if target < INF:
			var f2: float = target - c.s
			if f2 < free:
				free = f2
				obstacle_bound = false
		var v_des: float = c.vmax
		if c.ji < c.jc.size():
			var e3: Dictionary = c.jc[c.ji]
			if c.s > e3.s_box_in - 0.8 and c.s < e3.s_box_out:
				v_des = minf(Tuning.CAR_BOX_SPEED, c.vmax)
		var fpos: float = maxf(free, 0.0)
		var v_safe: float = sqrt(2.0 * Tuning.CAR_DECEL_COMFORT * fpos)
		var v_target: float = minf(v_des, v_safe)
		var v_new: float
		if v_target >= c.v:
			v_new = minf(v_target, c.v + c.accel * dt)
		else:
			var req_dec: float = c.v * c.v / (2.0 * maxf(fpos, 0.001))
			if obstacle_bound and obs != null and obs.kind == KIND_PED and req_dec > Tuning.HIYARI_DECEL:
				_hiyari(c, obs)
			var dec: float = clampf(req_dec, Tuning.CAR_DECEL_COMFORT, Tuning.CAR_DECEL_MAX)
			v_new = maxf(v_target, c.v - dec * dt)
		var ds: float = minf(v_new * dt, fpos)
		c.v = ds / dt if dt > 0.0 else 0.0
		c.s += ds
		c.waiting = c.v < 0.3
		if c.waiting:
			c.wait_t += dt
			c.stopped_total += dt
			max_stop_s = maxf(max_stop_s, c.wait_t)
		else:
			c.wait_t = 0.0
		if c.s >= c.length() - 0.01:
			c.done = true
			trips_done += 1
			car_delay_sum += c.t_alive - c.expected
			car_stops_sum += c.stopped_total
			car_done_n += 1
			continue
		c.pos = c.point_at(c.s)
		var ahead: Vector2 = c.point_at(c.s + 0.3)
		if ahead.distance_to(c.pos) > 0.001:
			c.dir = (ahead - c.pos).normalized()

func _hiyari(c: Car, p) -> void:
	if c.hiyari_ids.has(p.id):
		return
	c.hiyari_ids[p.id] = true
	hiyari_total += 1
	c.d = minf(100.0, c.d + Tuning.D_HIYARI_CAR * Tuning.T_D_SCALE)
	p.d = minf(100.0, p.d + Tuning.D_HIYARI_PED * Tuning.T_D_SCALE)
	_add_cause(c, "hiyari", Tuning.D_HIYARI_CAR * Tuning.T_D_SCALE)
	_add_cause(p, "hiyari", Tuning.D_HIYARI_PED * Tuning.T_D_SCALE)
	events.append({"pos": p.pos, "t": 0.0})
	for o in _near(p.pos):
		if o != c and o != p and o.pos.distance_to(p.pos) < Tuning.HIYARI_NEARBY_R:
			o.d = minf(100.0, o.d + Tuning.D_HIYARI_NEARBY)
			_add_cause(o, "hiyari", Tuning.D_HIYARI_NEARBY)

# ---------------------------------------------------------------------
# 歩行者
# ---------------------------------------------------------------------
func _crossing_safe(a: Vector2, b: Vector2) -> bool:
	var mid := (a + b) * 0.5
	for c in cars:
		if c.pos.distance_to(mid) > 8.0:
			continue
		if Geo.seg_dist(c.pos, a, b) < 1.0:
			var k := 0.0
			while k <= 1.0:
				if _car_rect_dist(c, a.lerp(b, k)) < Tuning.PED_RADIUS + 0.1:
					return false
				k += 0.08
		if c.v < 0.05:
			continue
		var stop_d: float = c.v * c.v / (2.0 * Tuning.CAR_DECEL_MAX) + Tuning.PED_SAFETY_MARGIN + Tuning.CAR_LENGTH * 0.5
		var ss: float = c.s
		var end: float = minf(c.s + stop_d, c.length())
		while ss <= end:
			if Geo.seg_dist(c.point_at(ss), a, b) < Tuning.CAR_DETECT_R + 0.1:
				return false
			ss += 0.5
	return true

static func _car_rect_dist(c: Car, p: Vector2) -> float:
	var rel := p - c.pos
	var fx: float = absf(rel.dot(c.dir)) - c.body_len * 0.5
	var fy: float = absf(rel.dot(Geo.left_of(c.dir))) - c.body_wid * 0.5
	return Vector2(maxf(fx, 0.0), maxf(fy, 0.0)).length()

func _ped_green_left(cx: Dictionary) -> float:
	if cx.sig < 0 or not signals.has(cx.sig):
		return INF
	return ped_left_of(signals[cx.sig], cx.arm)

func _step_peds(dt: float) -> void:
	for p in peds:
		p.t_alive += dt
		p.waiting = false
		if p.replan and not p.crossing:
			_replan_ped(p)
		var remain: float = dt * Tuning.PED_SPEED
		while remain > 0.0 and not p.done:
			if p.seg >= p.pts.size() - 1:
				p.done = true
				trips_done += 1
				break
			var a: Vector2 = p.pts[p.seg]
			var b: Vector2 = p.pts[p.seg + 1]
			var seg_len: float = a.distance_to(b)
			if p.u == 0.0 and p.cross.has(p.seg) and not p.crossing:
				var cx: Dictionary = p.cross[p.seg]
				var ok := true
				p.wait_signal = false
				var signaled: bool = cx.sig >= 0 and signals.has(cx.sig)
				if signaled and _ped_green_left(cx) < Tuning.PED_MIN_GREEN_LEFT:
					ok = false
					p.wait_signal = true
				if ok and not _crossing_safe(cx.a, cx.b):
					ok = false
				if not ok:
					p.waiting = true
					break
				p.crossing = true
				p.cross_b = cx.b
				if signaled:
					cross_walk += 1
				else:
					cross_jay += 1
			var step: float = minf(remain, seg_len - p.u)
			if p.crossing:
				var nxt: Vector2 = a.lerp(b, (p.u + step + 0.1) / maxf(seg_len, 0.0001))
				var blocked := false
				for o in _near(nxt):
					if o.kind == KIND_CAR and _car_rect_dist(o, nxt) < Tuning.PED_RADIUS + 0.03:
						blocked = true
						break
				if blocked and not p.forced:
					p.blocked_t += dt
					if p.blocked_t < 3.0:
						p.waiting = true
						break
					p.forced = true
					forced_moves += 1
				p.blocked_t = 0.0
			p.u += step
			remain -= step
			if p.u >= seg_len - 0.0001:
				if p.crossing and p.cross.has(p.seg):
					p.crossing = false
					p.forced = false
				p.seg += 1
				p.u = 0.0
		if not p.done and p.seg < p.pts.size() - 1:
			var a2: Vector2 = p.pts[p.seg]
			var b2: Vector2 = p.pts[p.seg + 1]
			var l: float = a2.distance_to(b2)
			p.pos = a2.lerp(b2, p.u / l) if l > 0.0001 else a2
			if l > 0.0001:
				p.dir = (b2 - a2) / l

# ---------------------------------------------------------------------
# 不満度・熱マップ・波
# ---------------------------------------------------------------------
## 赤信号で待っている（秩序ある待ち）
func _orderly_wait(x) -> bool:
	return (x.kind == KIND_PED and x.wait_signal) or (x.kind == KIND_CAR and (x.at_red or x.queue_orderly))

func _add_cause(x, key: String, v: float) -> void:
	x.cause[key] = x.cause.get(key, 0.0) + v

func cause_totals() -> Dictionary:
	var t := {}
	for x in cars:
		for k in x.cause:
			t[k] = t.get(k, 0.0) + x.cause[k]
	for x in peds:
		for k in x.cause:
			t[k] = t.get(k, 0.0) + x.cause[k]
	return t

func _update_discontent(dt: float) -> void:
	var all: Array = []
	all.append_array(cars)
	all.append_array(peds)
	var bump := {}
	for x in all:
		var sum := 0.0
		var cnt := 0
		for o in _near(x.pos):
			if o != x and o.waiting and not _orderly_wait(o) and o.pos.distance_to(x.pos) < Tuning.CONTAGION_R:
				sum += o.d
				cnt += 1
		if cnt > 0:
			var avg: float = sum / cnt
			if avg > x.d:
				bump[x] = Tuning.CONTAGION_RATE * (avg - x.d) * dt
	var total := 0.0
	for x in all:
		var dd := 0.0
		if x.waiting:
			x.wait_t += dt if x.kind == KIND_PED else 0.0
		else:
			if x.kind == KIND_PED:
				x.wait_t = 0.0
		if x.waiting and _orderly_wait(x):
			x.expected += dt          # 赤信号の待ちは予期された待ち。遅れには数えない
		var sig_wait: bool = x.kind == KIND_PED and x.wait_signal
		var tol := Tuning.WAIT_TOLERANCE_SIGNAL if (sig_wait or (x.kind == KIND_CAR and (x.at_red or x.queue_orderly))) else Tuning.WAIT_TOLERANCE
		if x.waiting and x.wait_t > tol:
			var rate := Tuning.D_WAIT_CAR
			var key := "jam"
			if x.kind == KIND_PED:
				rate = Tuning.T_D_RED_PED if sig_wait else Tuning.D_WAIT_PED
				key = "signal" if sig_wait else "jay"
			elif x.at_red or x.queue_orderly:
				rate = Tuning.T_D_RED_CAR      # 赤信号の待ちは、渋滞よりゆるい（秩序ある待ち）
				key = "signal"
			if key != "signal":
				rate *= Tuning.T_D_SCALE        # 倍率は衝突の不満だけ。信号待ち（秩序ある待ち）にはかけない
			dd += rate * dt
			_add_cause(x, key, rate * dt)
		elif not x.waiting:
			dd -= Tuning.D_DECAY * dt
		if x.t_alive > x.expected * Tuning.DELAY_FACTOR:
			dd += Tuning.D_DELAY * dt
			_add_cause(x, "delay", Tuning.D_DELAY * dt)
		var b: float = bump.get(x, 0.0)
		if b > 0.0:
			_add_cause(x, "spread", b)
		dd += b
		x.d = clampf(x.d + dd, 0.0, 100.0)
		total += x.d
	# ゲージ: 不満が高い上位K人の平均（空きは0）。街が広くても薄まらず、混んだ場所の不満が見える
	var ds := PackedFloat32Array()
	for x in all:
		ds.append(x.d)
	ds.sort()
	var top := 0.0
	var kk := mini(Tuning.T_GAUGE_K, ds.size())
	for i in kk:
		top += ds[ds.size() - 1 - i]
	var target := top / float(Tuning.T_GAUGE_K)
	gauge += (target - gauge) * (1.0 - exp(-Tuning.GAUGE_SMOOTH * dt))
	max_gauge = maxf(max_gauge, gauge)
	if gauge >= Tuning.T_GAUGE_LIMIT:
		over_limit_game_s += dt * Tuning.CLOCK_RATE
		if over_limit_game_s >= Tuning.FAIL_GAME_SECONDS:
			fail_reached = true
	else:
		over_limit_game_s = 0.0

func _update_heat_and_waves(dt: float) -> void:
	var k := exp(-dt / Tuning.HEAT_TAU)
	for key in heat.keys():
		var v: float = heat[key] * k
		if v < 0.02:
			heat.erase(key)
		else:
			heat[key] = v
	for x in cars:
		if x.waiting:
			var c := _cell(x.pos)
			heat[c] = heat.get(c, 0.0) + dt * (0.5 + x.d / 100.0)
	for x in peds:
		if x.waiting:
			var c := _cell(x.pos)
			heat[c] = heat.get(c, 0.0) + dt * (0.5 + x.d / 100.0)
	for w in waves:
		var r0: float = w.r
		var r1: float = r0 + Tuning.WAVE_SPEED * dt
		w.r = r1
		for x in cars:
			var dist: float = x.pos.distance_to(w.c)
			if dist >= r0 and dist < r1:
				x.d *= 1.0 - Tuning.WAVE_RELIEF
				x.pulse = 1.0
		for x in peds:
			var dist: float = x.pos.distance_to(w.c)
			if dist >= r0 and dist < r1:
				x.d *= 1.0 - Tuning.WAVE_RELIEF
				x.pulse = 1.0
	waves = waves.filter(func(w): return w.r < Tuning.WAVE_MAX_R)
	for x in cars:
		x.pulse = maxf(0.0, x.pulse - dt * 1.5)
	for x in peds:
		x.pulse = maxf(0.0, x.pulse - dt * 1.5)

# ---------------------------------------------------------------------
# 不満バブル（待たされている人の頭上に出る。弾くと開発ポイント）
# ---------------------------------------------------------------------
func _update_bubbles(rdt: float) -> void:
	var keep: Array = []
	for b in bubbles:
		b.age += rdt
		var a = b.agent
		if a.done:
			_end_bubble(b, false)
			continue
		if auto_collect and b.auto_at >= 0.0 and b.age >= b.auto_at:
			_collect(b)
			continue
		if b.age >= b.life:
			_end_bubble(b, false)
			continue
		keep.append(b)
	bubbles = keep
	_since_collect += rdt
	if bubbles.size() >= Tuning.T_BUBBLE_CAP:
		return
	var elig: Array = []
	for x in cars:
		if _bubble_eligible(x):
			elig.append(x)
	for x in peds:
		if _bubble_eligible(x):
			elig.append(x)
	if elig.is_empty():
		_bubble_acc = minf(_bubble_acc, 0.5)
		return
	# 出現率: 待っている人が多いほど上がり、出現総数が増えるほど下がる（自己調整）。停滞すると上がる
	var rate: float = Tuning.T_BUBBLE_RATE * minf(1.0, elig.size() / 4.0) / (1.0 + bubble_stats.spawned / Tuning.T_BUBBLE_DECAY)
	if funds < 50 and _since_collect > 15.0:
		rate *= Tuning.T_BUBBLE_BOOST
	_bubble_acc += rate * rdt
	if _bubble_acc >= 1.0:
		_bubble_acc -= 1.0
		var x = elig[_bub_rng.randi_range(0, elig.size() - 1)]
		var life := _bub_rng.randf_range(Tuning.T_BUBBLE_LIFE[0], Tuning.T_BUBBLE_LIFE[1])
		var auto_at := life * _bub_rng.randf_range(0.3, 0.8) if _bub_rng.randf() < Tuning.T_BUBBLE_AUTO else -1.0
		bubbles.append({"id": _bubble_id, "agent": x, "age": 0.0, "life": life, "auto_at": auto_at})
		_bubble_id += 1
		x.has_bubble = true
		bubble_stats.spawned += 1

func _bubble_eligible(x) -> bool:
	return x.waiting and not x.has_bubble and x.wait_t > Tuning.T_BUBBLE_WAIT and sig_clock >= x.bubble_ready_at

func _end_bubble(b: Dictionary, collected: bool) -> void:
	b.agent.has_bubble = false
	b.agent.bubble_ready_at = sig_clock + Tuning.T_BUBBLE_COOLDOWN
	if not collected:
		bubble_stats.missed += 1

func _collect(b: Dictionary) -> void:
	_end_bubble(b, true)
	funds += Tuning.T_BUBBLE_VALUE
	bubble_stats.collected += 1
	_since_collect = 0.0
	income_log.append([clock_hours(), funds])
	b.collected = true

## タップで弾く（第2回で使う）。弾けたら true
func pop_bubble(id: int) -> bool:
	for i in bubbles.size():
		if bubbles[i].id == id:
			var b: Dictionary = bubbles[i]
			bubbles.remove_at(i)
			_collect(b)
			return true
	return false

func _cleanup() -> void:
	for c in cars:
		if c.done:
			# 予約したまま消える車の区画を返す
			for e in c.jc:
				if e.state == 1:
					_held[e.j] &= ~e.quads
	cars = cars.filter(func(c): return not c.done)
	peds = peds.filter(func(p): return not p.done)
