class_name SimWorld
extends RefCounted
## 交通シミュレーション本体（純ロジック。Node や見た目に依存しない）。
## 時間の単位はシム秒（通常速度での実時間の秒数）。

const KIND_CAR := 0
const KIND_PED := 1

class Car:
	var id: int
	var kind := 0
	var pts: PackedVector2Array
	var s := 0.0
	var v := 0.0
	var pos := Vector2.ZERO
	var dir := Vector2.RIGHT
	var arm_in := 0
	var s_stop := 0.0      # 信号の停止位置（車の中心）
	var s_req := 0.0       # 信号なしで交差点進入を待つ位置
	var s_box_in := 0.0
	var s_box_out := 0.0
	var quads := 0
	var has_res := false
	var entered := false   # 交差点に進入済み（予約を返した後も再要求しない）
	var requesting := false
	var stop_target := 0.0   # 今止まるべき位置（停止線 または 交差点の手前）
	var standoff := -1.0   # 信号なしで鉢合わせたときの残りためらい時間（-1 = 未判定）
	var d := 0.0
	var t_alive := 0.0
	var expected := 1.0
	var waiting := false
	var wait_t := 0.0
	var hiyari_ids := {}
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
	var cross := {}        # 区間番号 -> {a, b, crosswalk, arm}
	var crossing := false  # 道路上を横断中
	var cross_b := Vector2.ZERO  # 横断の終点
	var pos := Vector2.ZERO
	var d := 0.0
	var t_alive := 0.0
	var expected := 1.0
	var waiting := false
	var wait_t := 0.0
	var wait_signal := false  # 赤信号で待っている（秩序ある待ち）
	var blocked_t := 0.0
	var forced := false
	var dest_block := 0
	var dest_arm := 0
	var dest_t := 0.0
	var done := false

# ---- 状態 ----
var cars: Array = []
var peds: Array = []
var clock_s := 0.0            # ゲーム内時刻（秒）
var funds := Tuning.START_FUNDS
var gauge := 0.0
var hiyari_total := 0
var max_gauge := 0.0
var over_limit_game_s := 0.0  # ゲージが上限のまま続いたゲーム内秒数
var fail_reached := false
var cross_jay := 0            # 無断横断の回数
var cross_walk := 0           # 信号のある横断歩道での横断の回数
var forced_moves := 0         # 道路上で詰まった歩行者を強制的に進めた回数（デッドロック回避の安全弁）
var events: Array = []        # ヒヤリの発生位置 {pos, t}
var last_loop := {}           # 前回ループの結果
var loop_count := 0
var seed_base := 20261124   # 発生列の種（同じ種なら毎ループ同じ発生列）

# 信号（試作では交差点に1基のみ）
var signal_on := false
var signal_preset := 1
var signal_phase := 0
var signal_t := 0.0

var _next_id := 1
var _held_quads := 0
var _hash := {}
var _crossers: Array = []
var _spawn_rng := RandomNumberGenerator.new()
var _route_rng := RandomNumberGenerator.new()
var _misc_rng := RandomNumberGenerator.new()
var _ped_acc := 0.0
var _car_acc := 0.0
var _gauge_sum := 0.0

func _init() -> void:
	reset_loop()

func reset_loop() -> void:
	cars.clear()
	peds.clear()
	events.clear()
	clock_s = Tuning.LOOP_START_H * 3600.0
	gauge = 0.0
	max_gauge = 0.0
	hiyari_total = 0
	over_limit_game_s = 0.0
	fail_reached = false
	cross_jay = 0
	cross_walk = 0
	forced_moves = 0
	_held_quads = 0
	_ped_acc = 0.0
	_car_acc = 0.0
	# 同じ種で毎ループ同じ発生列にする（信号あり／なしを同条件で比べられる）
	_spawn_rng.seed = seed_base
	_route_rng.seed = seed_base + 7
	_misc_rng.seed = seed_base + 99

func clock_hours() -> float:
	return clock_s / 3600.0

# =====================================================================
# 信号機
# =====================================================================
func place_signal(preset: int) -> bool:
	if signal_on or funds < Tuning.SIGNAL_COST:
		return false
	funds -= Tuning.SIGNAL_COST
	signal_on = true
	signal_preset = preset
	signal_phase = 0
	signal_t = 0.0
	_replan_peds()
	return true

func demolish_signal() -> void:
	if not signal_on:
		return
	signal_on = false
	funds += int(Tuning.SIGNAL_COST * Tuning.DEMOLISH_REFUND_RATE)
	_replan_peds()

func set_signal_preset(preset: int) -> void:
	signal_preset = preset

func _phase_dur(ph: int) -> float:
	match ph:
		0, 3:
			return Tuning.SIGNAL_GREEN[signal_preset]
		1, 4:
			return Tuning.SIGNAL_YELLOW
		_:
			return Tuning.SIGNAL_ALL_RED

func _step_signal(dt: float) -> void:
	if not signal_on:
		return
	signal_t += dt
	while signal_t >= _phase_dur(signal_phase):
		signal_t -= _phase_dur(signal_phase)
		signal_phase = (signal_phase + 1) % 6

## 東西（0,1）= A系統、南北（2,3）= B系統
static func _axis(arm: int) -> int:
	return 0 if arm <= 1 else 1

## 車の信号: 0=青 1=黄 2=赤
func car_light(arm: int) -> int:
	if not signal_on:
		return 0
	var ax := _axis(arm)
	var base := 0 if ax == 0 else 3
	if signal_phase == base:
		return 0
	if signal_phase == base + 1:
		return 1
	return 2

## 歩行者の信号: 道路 arm を横断する歩行者は、その道路と直交する系統の車と同時に青
func ped_green_left(arm: int) -> float:
	if not signal_on:
		return INF
	var ax := 1 - _axis(arm)
	var base := 0 if ax == 0 else 3
	if signal_phase == base:
		return _phase_dur(base) - signal_t
	return -1.0

# =====================================================================
# メインループ
# =====================================================================
func step(dt: float) -> void:
	clock_s += dt * Tuning.CLOCK_RATE
	_step_signal(dt)
	_spawn(dt)
	_build_hash()
	_step_cars(dt)
	_step_peds(dt)
	_update_discontent(dt)
	_cleanup()
	# イベント表示の寿命
	for e in events:
		e.t += dt
	events = events.filter(func(e): return e.t < 1.5)
	if clock_hours() >= Tuning.LOOP_END_H:
		last_loop = {"max_gauge": max_gauge, "hiyari": hiyari_total,
			"cross_jay": cross_jay, "cross_walk": cross_walk,
			"signal": signal_on, "fail": fail_reached, "forced": forced_moves}
		loop_count += 1
		reset_loop()

# =====================================================================
# 発生（朝ピークの簡易プロファイル）
# =====================================================================
func _rate(base: float, peak: float) -> float:
	var h := clock_hours()
	var x := (h - Tuning.PEAK_H) / Tuning.PEAK_W
	return base + peak * exp(-x * x)

func _spawn(dt: float) -> void:
	_ped_acc += _rate(Tuning.PED_RATE_BASE, Tuning.PED_RATE_PEAK) * dt
	while _ped_acc >= 1.0:
		_ped_acc -= 1.0
		_spawn_ped()
	_car_acc += _rate(Tuning.CAR_RATE_BASE, Tuning.CAR_RATE_PEAK) * dt
	while _car_acc >= 1.0:
		_car_acc -= 1.0
		_spawn_car()

func _door_t(rng: RandomNumberGenerator) -> float:
	var u := pow(rng.randf(), Tuning.DOOR_NEAR_BIAS)
	return lerpf(Tuning.DOOR_T_MIN, Tuning.DOOR_T_MAX, u)

func _spawn_ped() -> void:
	var r := _spawn_rng
	var a := r.randi_range(0, 3)
	var b := (a + r.randi_range(1, 3)) % 4
	var arms_a := Geo.block_arms(a)
	var arms_b := Geo.block_arms(b)
	var arm_a: int = arms_a[r.randi_range(0, 1)]
	var arm_b: int = arms_b[r.randi_range(0, 1)]
	var t_a := _door_t(r)
	var t_b := _door_t(r)
	var p := Ped.new()
	p.id = _next_id
	_next_id += 1
	p.dest_block = b
	p.dest_arm = arm_b
	p.dest_t = t_b
	var plan := _plan_ped(a, arm_a, t_a, b, arm_b, t_b, r.randf(), r.randf())
	p.pts = plan.pts
	p.cross = plan.cross
	p.expected = plan.ideal_len / Tuning.PED_SPEED
	p.pos = p.pts[0]
	peds.append(p)

func _spawn_car() -> void:
	var r := _spawn_rng
	var a := r.randi_range(0, 3)
	var b := (a + r.randi_range(1, 3)) % 4
	var arms_a := Geo.block_arms(a)
	var arms_b := Geo.block_arms(b)
	var arm_in: int = arms_a[r.randi_range(0, 1)]
	var cand: Array = arms_b.filter(func(x): return x != arm_in)
	var arm_out: int = cand[r.randi_range(0, cand.size() - 1)]
	var r_in := r.randf_range(Tuning.CAR_DOOR_R_MIN, Tuning.CAR_DOOR_R_MAX)
	var r_out := r.randf_range(Tuning.CAR_DOOR_R_MIN, Tuning.CAR_DOOR_R_MAX)
	var start := Geo.inbound_point(arm_in, r_in)
	# 出入口が詰まっていたら発生を見送る
	for c in cars:
		if c.pos.distance_to(start) < Tuning.CAR_LENGTH + Tuning.CAR_GAP_CAR:
			return
	# 横断中の歩行者の通り道の上には出さない
	for q in peds:
		if q.crossing and Geo.seg_dist(start, q.pos, q.cross_b) < Tuning.CAR_LENGTH + 0.3:
			return
	var c := Car.new()
	c.id = _next_id
	_next_id += 1
	c.arm_in = arm_in
	var poly := PackedVector2Array()
	poly.append(start)
	var curve := Geo.box_curve(arm_in, arm_out)
	for q in curve:
		poly.append(q)
	poly.append(Geo.outbound_point(arm_out, r_out))
	c.pts = Geo.resample(poly)
	var curve_len := 0.0
	for i in range(curve.size() - 1):
		curve_len += curve[i].distance_to(curve[i + 1])
		c.quads |= Geo.quad_bit(curve[i].lerp(curve[i + 1], 0.5))
	var half := Tuning.CAR_LENGTH * 0.5
	c.s_box_in = r_in - Tuning.ROAD_HALF
	c.s_box_out = c.s_box_in + curve_len
	c.s_stop = r_in - Tuning.STOP_LINE_R - half
	c.s_req = r_in - (Tuning.ROAD_HALF + 0.05) - half
	c.expected = c.length() / Tuning.CAR_SPEED
	c.pos = start
	c.dir = (c.pts[1] - c.pts[0]).normalized()
	cars.append(c)

# =====================================================================
# 歩行者の経路
# =====================================================================
## 1本の道路を渡る区間を計画する。戻り値: {t, crosswalk, ideal_t}
func _plan_leg(k: int, arm_o: int, t_o: float, arm_d: int, t_d: float, u: float) -> Dictionary:
	var t_j: float
	if arm_o == k and arm_d == k:
		t_j = lerpf(minf(t_o, t_d), maxf(t_o, t_d), u)
	elif arm_o == k:
		t_j = lerpf(0.0, t_o, u)
	elif arm_d == k:
		t_j = lerpf(0.0, t_d, u)
	else:
		t_j = 0.0
	t_j = maxf(t_j, 0.3)
	var cost_j := Geo.walk_dist(arm_o, t_o, k, t_j) + Geo.walk_dist(k, t_j, arm_d, t_d)
	var t_c := Tuning.CROSSWALK_T
	var cost_c := Geo.walk_dist(arm_o, t_o, k, t_c) + Geo.walk_dist(k, t_c, arm_d, t_d)
	var use_cw := signal_on and (cost_c - cost_j) <= Tuning.PED_DETOUR_MAX
	return {"t": t_c if use_cw else t_j, "crosswalk": use_cw, "ideal": cost_j}

func _plan_ped(a: int, arm_a: int, t_a: float, b: int, arm_b: int, t_b: float, u1: float, u2: float) -> Dictionary:
	var pts := PackedVector2Array()
	var cross := {}
	pts.append(Geo.walk_point(a, arm_a, t_a))
	var ideal := 0.0
	var legs: Array = []  # [from_block, to_block]
	var k := Geo.shared_arm(a, b)
	if k >= 0:
		legs.append([a, b])
	else:
		# 対角: どちらかの隣のエリアを経由する（近い方）
		var m1 := -1
		var m2 := -1
		for m in 4:
			if m != a and m != b and Geo.shared_arm(a, m) >= 0 and Geo.shared_arm(m, b) >= 0:
				if m1 < 0:
					m1 = m
				else:
					m2 = m
		var cost1 := Geo.walk_dist(arm_a, t_a, Geo.shared_arm(a, m1), 0) + Geo.walk_dist(Geo.shared_arm(m1, b), 0, arm_b, t_b)
		var cost2 := Geo.walk_dist(arm_a, t_a, Geo.shared_arm(a, m2), 0) + Geo.walk_dist(Geo.shared_arm(m2, b), 0, arm_b, t_b)
		var m := m1 if (cost1 < cost2 or (is_equal_approx(cost1, cost2) and u2 < 0.5)) else m2
		legs.append([a, m])
		legs.append([m, b])
	var cur_block := a
	var cur_arm := arm_a
	var cur_t := t_a
	for li in legs.size():
		var from_b: int = legs[li][0]
		var to_b: int = legs[li][1]
		var kk := Geo.shared_arm(from_b, to_b)
		var d_arm: int
		var d_t: float
		if li == legs.size() - 1:
			d_arm = arm_b
			d_t = t_b
		else:
			d_arm = Geo.shared_arm(to_b, legs[li + 1][1])
			d_t = 0.0
		var plan := _plan_leg(kk, cur_arm, cur_t, d_arm, d_t, u1 if li == 0 else u2)
		var t: float = plan.t
		ideal += plan.ideal + 3.0
		# 歩道を横断地点まで歩く
		if cur_arm != kk:
			pts.append(Geo.block_corner(from_b))
		var pa := Geo.walk_point(from_b, kk, t)
		var pb := Geo.walk_point(to_b, kk, t)
		pts.append(pa)
		cross[pts.size() - 1] = {"a": pa, "b": pb, "crosswalk": plan.crosswalk, "arm": kk}
		pts.append(pb)
		cur_block = to_b
		cur_arm = kk
		cur_t = t
	if cur_arm != arm_b:
		pts.append(Geo.block_corner(b))
	pts.append(Geo.walk_point(b, arm_b, t_b))
	return {"pts": pts, "cross": cross, "ideal_len": ideal}

## 信号の設置・撤去後、まだ道路を渡り始めていない歩行者の経路を引き直す
func _replan_peds() -> void:
	for p in peds:
		if p.crossing:
			continue
		var q: Vector2 = p.pos
		if minf(absf(q.x), absf(q.y)) < Tuning.WALK_OFFSET - 0.1:
			continue
		var blk: int = Geo.block_of(q)
		if blk == p.dest_block and Geo.shared_arm(blk, p.dest_block) < 0:
			continue
		var loc: Array = Geo.walk_locate(blk, q)
		if blk == p.dest_block:
			continue
		var plan: Dictionary = _plan_ped(blk, loc[0], loc[1], p.dest_block, p.dest_arm, p.dest_t,
			_route_rng.randf(), _route_rng.randf())
		p.pts = plan.pts
		p.cross = plan.cross
		p.seg = 0
		p.u = 0.0

# =====================================================================
# 空間ハッシュ（近傍探索用）
# =====================================================================
func _cell(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x), floori(p.y))

func _build_hash() -> void:
	_hash.clear()
	_crossers = peds.filter(func(q): return q.crossing)
	for c in cars:
		var k: Vector2i = _cell(c.pos)
		if not _hash.has(k):
			_hash[k] = []
		_hash[k].append(c)
	for p in peds:
		var k: Vector2i = _cell(p.pos)
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

# =====================================================================
# 車両
# =====================================================================
## 進路上の最も近い障害物までの余裕距離。戻り値 [free, obstacle]
## 車は「横断中の歩行者がこれから通る線（現在位置〜横断の終点）」も障害物として扱い、
## その手前で止まる（歩行者 > 車両の優先と、接触ゼロの保証）。
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

func _exit_clear(c: Car) -> bool:
	var i0 := int(c.s_box_out / Geo.SAMPLE)
	var i1 := mini(c.pts.size() - 1, int((c.s_box_out + Tuning.CAR_LENGTH + 0.4) / Geo.SAMPLE))
	for i in range(i0, i1 + 1, 2):
		for o in _near(c.pts[i]):
			if o != c and o.kind == KIND_CAR and c.pts[i].distance_to(o.pos) < Tuning.CAR_DETECT_R:
				return false
	return true

func _step_cars(dt: float) -> void:
	# 1) 交差点の区画の解放
	for c in cars:
		if c.has_res and c.s - Tuning.CAR_LENGTH * 0.5 > c.s_box_out:
			c.has_res = false
			_held_quads &= ~c.quads
	# 2) 進入要求と許可（信号なしは順番を守らない＝ランダム）
	#    信号あり: 赤・黄（止まれる場合）は停止線で止まる。青なら交差点の手前まで進んで要求する。
	#    停止線を越えた車（右折待ちなど）は信号に関係なく、空いたら抜けてよい。
	var req: Array = []
	for c in cars:
		c.requesting = false
		c.stop_target = c.s_req
		if c.has_res or c.entered:
			continue
		var committed: bool = signal_on and c.s > c.s_stop + 0.05
		if signal_on and not committed:
			var light: int = car_light(c.arm_in)
			var to_line: float = c.s_stop - c.s
			if light == 2 or (light == 1 and to_line > c.v * c.v / (2.0 * Tuning.CAR_DECEL_COMFORT)):
				c.stop_target = c.s_stop
				continue
		var dist: float = c.s_req - c.s
		var near_enough: bool = dist < c.v * c.v / (2.0 * Tuning.CAR_DECEL_COMFORT) + 0.6
		if not near_enough:
			continue
		# 先頭の車だけが要求できる（列の後ろの車が先に区画を押さえると詰まるため）
		var sc0: Array = _scan_ahead(c)
		if sc0[1] != null and sc0[1].kind == KIND_CAR and sc0[0] < dist + 0.2:
			continue
		c.requesting = true
		req.append(c)
	if not signal_on:
		# 譲り合わない: 交差する相手と鉢合わせると、互いにためらって時間を失う
		for c in req:
			if c.standoff < 0.0:
				var conflict := false
				for o in req:
					if o != c and (o.quads & c.quads) != 0:
						conflict = true
						break
				c.standoff = _misc_rng.randf_range(Tuning.CAR_STANDOFF_MIN, Tuning.CAR_STANDOFF_MAX) if conflict else 0.0
			c.standoff -= dt
	# 種付きの乱数でシャッフル（再現性のため）
	for i in range(req.size() - 1, 0, -1):
		var j := _misc_rng.randi_range(0, i)
		var tmp = req[i]
		req[i] = req[j]
		req[j] = tmp
	for c in req:
		if not signal_on and c.standoff > 0.0:
			continue
		if (_held_quads & c.quads) != 0:
			continue
		if signal_on and not _exit_clear(c):
			continue
		c.has_res = true
		_held_quads |= c.quads
	# 3) 走行
	for c in cars:
		c.t_alive += dt
		var sc: Array = _scan_ahead(c)
		var free: float = sc[0]
		var obs = sc[1]
		var obstacle_bound := true
		if c.has_res and c.s >= c.s_box_in - 0.1:
			c.entered = true
		if not c.has_res and not c.entered:
			var f2: float = c.stop_target - c.s
			if f2 < free:
				free = f2
				obstacle_bound = false
		var v_des := Tuning.CAR_SPEED
		if c.s > c.s_box_in - 0.8 and c.s < c.s_box_out:
			v_des = Tuning.CAR_BOX_SPEED
		var fpos: float = maxf(free, 0.0)
		var v_safe: float = sqrt(2.0 * Tuning.CAR_DECEL_COMFORT * fpos)
		var v_target: float = minf(v_des, v_safe)
		var v_new: float
		if v_target >= c.v:
			v_new = minf(v_target, c.v + Tuning.CAR_ACCEL * dt)
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
		if c.s >= c.length() - 0.01:
			c.done = true
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
	c.d = minf(100.0, c.d + Tuning.D_HIYARI_CAR)
	p.d = minf(100.0, p.d + Tuning.D_HIYARI_PED)
	events.append({"pos": p.pos, "t": 0.0})
	for o in _near(p.pos):
		if o != c and o != p and o.pos.distance_to(p.pos) < Tuning.HIYARI_NEARBY_R:
			o.d = minf(100.0, o.d + Tuning.D_HIYARI_NEARBY)

# =====================================================================
# 歩行者
# =====================================================================
## 横断区間 a-b に、止まりきれない車・車体がないか
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

		# 止まっている車は、動き出す前に歩行者を見て止まるので車体だけを見る
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

## 車体との距離（矩形と点）
static func _car_rect_dist(c: Car, p: Vector2) -> float:
	var rel := p - c.pos
	var fx: float = absf(rel.dot(c.dir)) - Tuning.CAR_LENGTH * 0.5
	var fy: float = absf(rel.dot(Geo.left_of(c.dir))) - Tuning.CAR_WIDTH * 0.5
	return Vector2(maxf(fx, 0.0), maxf(fy, 0.0)).length()

func _step_peds(dt: float) -> void:
	for p in peds:
		p.t_alive += dt
		p.waiting = false
		var remain: float = dt * Tuning.PED_SPEED
		while remain > 0.0 and not p.done:
			if p.seg >= p.pts.size() - 1:
				p.done = true
				break
			var a: Vector2 = p.pts[p.seg]
			var b: Vector2 = p.pts[p.seg + 1]
			var seg_len: float = a.distance_to(b)
			# 横断区間の手前: 渡ってよいか判断する
			if p.u == 0.0 and p.cross.has(p.seg) and not p.crossing:
				var cx: Dictionary = p.cross[p.seg]
				var ok := true
				p.wait_signal = false
				if cx.crosswalk and signal_on:
					if ped_green_left(cx.arm) < Tuning.PED_MIN_GREEN_LEFT:
						ok = false
						p.wait_signal = true
				if ok and not _crossing_safe(cx.a, cx.b):
					ok = false
				if not ok:
					p.waiting = true
					break
				p.crossing = true
				p.cross_b = cx.b
				if cx.crosswalk and signal_on:
					cross_walk += 1
				else:
					cross_jay += 1
			# 横断中: 目の前に車体があれば待つ（接触しないための安全弁）
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
					# 安全弁: 3秒以上お互いに動けない場合は歩行者を通す（回数を記録）
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

# =====================================================================
# 不満度
# =====================================================================
func _update_discontent(dt: float) -> void:
	var all: Array = []
	all.append_array(cars)
	all.append_array(peds)
	# 伝染: 近くで待つ人の不満が少しずつ広がる
	var bump := {}
	for x in all:
		var sum := 0.0
		var cnt := 0
		for o in _near(x.pos):
			if o != x and o.waiting and o.pos.distance_to(x.pos) < Tuning.CONTAGION_R:
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
			x.wait_t += dt
		else:
			x.wait_t = 0.0
		var sig_wait: bool = x.kind == KIND_PED and x.wait_signal
		var tol := Tuning.WAIT_TOLERANCE_SIGNAL if sig_wait else Tuning.WAIT_TOLERANCE
		if x.waiting and x.wait_t > tol:
			var rate := Tuning.D_WAIT_CAR
			if x.kind == KIND_PED:
				rate = Tuning.D_WAIT_PED_SIGNAL if sig_wait else Tuning.D_WAIT_PED
			dd += rate * dt
		elif not x.waiting:
			dd -= Tuning.D_DECAY * dt
		if x.t_alive > x.expected * Tuning.DELAY_FACTOR:
			dd += Tuning.D_DELAY * dt
		dd += bump.get(x, 0.0)
		x.d = clampf(x.d + dd, 0.0, 100.0)
		total += x.d
	var target := total / maxf(float(all.size()), Tuning.GAUGE_POP_FLOOR)
	gauge += (target - gauge) * (1.0 - exp(-Tuning.GAUGE_SMOOTH * dt))
	max_gauge = maxf(max_gauge, gauge)
	if gauge >= Tuning.GAUGE_LIMIT:
		over_limit_game_s += dt * Tuning.CLOCK_RATE
		if over_limit_game_s >= Tuning.FAIL_GAME_SECONDS:
			fail_reached = true
	else:
		over_limit_game_s = 0.0

func _cleanup() -> void:
	for c in cars:
		if c.done and c.has_res:
			_held_quads &= ~c.quads
	cars = cars.filter(func(c): return not c.done)
	peds = peds.filter(func(p): return not p.done)
