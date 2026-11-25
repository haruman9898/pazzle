extends SceneTree
## ステージ1（1日 6:00→翌6:00）のヘッドレス検証
##   godot --headless --script res://tests/stage1_test.gd -- --none      信号なしの1日（複数の種）
##   godot --headless --script res://tests/stage1_test.gd -- --sweep     1基だけ置いたときの総当たり（時間帯ごとの最大）
## 時間帯: 朝 6.5〜10 / 昼 10〜15 / 夕 15〜20 / 夜 20〜30

const WINDOWS := {"朝": [6.5, 10.0], "昼": [10.0, 15.0], "夕": [15.0, 20.0], "夜": [20.0, 30.0]}
const SEEDS := [Tuning.T_SEED, 11, 22]

func _contacts(w: TownWorld) -> int:
	var n := 0
	for p in w.peds:
		for c in w.cars:
			if c.pos.distance_to(p.pos) > 1.0:
				continue
			if TownWorld._car_rect_dist(c, p.pos) < Tuning.PED_RADIUS - 0.02:
				n += 1
	for i in w.cars.size():
		for j in range(i + 1, w.cars.size()):
			var a = w.cars[i]
			var b = w.cars[j]
			if a.pos.distance_to(b.pos) < minf(a.body_wid, b.body_wid) * 0.9:
				n += 1
	return n

## policy: Callable(w: TownWorld, hour: float) -> void。1ステップごとに呼ばれる
func run_day(policy: Callable, seed := Tuning.T_SEED, preset := 1) -> Dictionary:
	var w := TownWorld.new()
	w.seed_base = seed
	w.auto_loop = false
	w.reset_loop()
	var winmax := {}
	for k in WINDOWS:
		winmax[k] = 0.0
	var contacts := 0
	var steps := 0
	var traj: Array = []
	var next_sample := 6.0
	var t0 := Time.get_ticks_msec()
	while not w.day_over and steps < 20000:
		policy.call(w, w.clock_hours())
		w.step(Tuning.SIM_DT, Tuning.SIM_DT)
		steps += 1
		if steps % 3 == 0:
			contacts += _contacts(w)
		var h := w.clock_hours()
		if h >= next_sample:
			traj.append([h, w.gauge, w.cars.size(), w.peds.size(), w.funds, w.bubble_stats.collected])
			next_sample += 1.0
		for k in WINDOWS:
			if h >= WINDOWS[k][0] and h < WINDOWS[k][1]:
				winmax[k] = maxf(winmax[k], w.gauge)
	var r := {"win": winmax, "fail": w.fail_reached, "fail_h": w.fail_clock, "contacts": contacts,
		"max_stop": w.max_stop_s, "hiyari": w.hiyari_total, "trips": w.trips_done, "funds": w.funds,
		"bub": w.bubble_stats.duplicate(), "decisions": w.decisions, "ms": float(Time.get_ticks_msec() - t0) / steps,
		"income": w.income_log.duplicate(), "traj": traj}
	return r

func fmt_win(r: Dictionary) -> String:
	var parts := []
	for k in WINDOWS:
		parts.append("%s%d" % [k, int(r.win[k])])
	return " ".join(parts)

func show(label: String, r: Dictionary) -> void:
	print("[%s] %s 失敗=%s 接触=%d 最長停止=%.1fs ヒヤリ=%d 到着=%d バブル出/回収/逃=%d/%d/%d ポイント=%d ms=%.2f" % [
		label, fmt_win(r), "はい(%.1f時)" % r.fail_h if r.fail else "いいえ", r.contacts, r.max_stop, r.hiyari, r.trips,
		r.bub.spawned, r.bub.collected, r.bub.missed, r.funds, r.ms])

func candidates(w: TownWorld) -> Array:
	var out: Array = []
	for j in 4:
		var pl := w.placement_at(TownMap.junction_center(j))
		out.append(["交差点%d" % j, pl])
	for l in TownMap.LINE_COUNT:
		var t := -float(TownMap.EXT) + 0.5
		while t < float(TownMap.EXT):
			var pl := w.placement_at(TownMap.line_point(l, t))
			if pl.ok and pl.kind == 1:
				out.append(["路上 線%d t=%.1f" % [l, t], pl])
			t += 1.0
	return out

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var none := func(_w, _h): pass
	if "--none" in args:
		for sd in SEEDS:
			show("信号なし 種%d" % sd, run_day(none, sd))
	if "--traj" in args:
		var r := run_day(none)
		show("信号なし", r)
		for t in r.traj:
			print("  %4.1f時 ゲージ%3d 車%2d 人%3d ポイント%3d 回収%2d" % [t[0], int(t[1]), t[2], t[3], t[4], t[5]])
	if "--key" in args:
		# 主要な置き方だけを、種3つの平均で比べる
		var w1 := TownWorld.new()
		var keys := {"なし": null}
		for j in 4:
			keys["交差点%d" % j] = w1.placement_at(TownMap.junction_center(j))
		keys["学校前 普通"] = w1.placement_at(TownMap.line_point(2, 0.5))
		keys["学校前 短い"] = w1.placement_at(TownMap.line_point(2, 0.5))
		keys["学校前 長い"] = w1.placement_at(TownMap.line_point(2, 0.5))
		keys["交差点0 短い"] = w1.placement_at(TownMap.junction_center(0))
		keys["交差点0 長い"] = w1.placement_at(TownMap.junction_center(0))
		for name in keys:
			var tot := {"朝": 0.0, "昼": 0.0, "夕": 0.0, "夜": 0.0}
			var fails := 0
			for sd in SEEDS:
				var pl = keys[name]
				var pv := 0 if name.ends_with("短い") else (2 if name.ends_with("長い") else 1)
				var pol := func(w, _h):
					if pl != null and w.signals.is_empty() and w.clock_hours() < 6.01:
						w.place_signal_at(pl, pv)
						w.waves.clear()
				var r := run_day(pol, sd)
				for k in tot:
					tot[k] += r.win[k]
				if r.fail:
					fails += 1
			print("[%s] 朝%d 昼%d 夕%d 夜%d 失敗%d/%d" % [name, tot["朝"] / SEEDS.size(), tot["昼"] / SEEDS.size(), tot["夕"] / SEEDS.size(), tot["夜"] / SEEDS.size(), fails, SEEDS.size()])
	if "--play" in args:
		# 疑似プレイヤー: 開発ポイントが100たまるたびに、優先順位の順に信号を置く（間隔は「短い」）
		var w2 := TownWorld.new()
		var order_sets := {
			"交差点0→学校前→交差点3→交差点1": [w2.placement_at(TownMap.junction_center(0)), w2.placement_at(TownMap.line_point(2, 0.5)), w2.placement_at(TownMap.junction_center(3)), w2.placement_at(TownMap.junction_center(1))],
			"学校前→交差点0→交差点3→交差点1": [w2.placement_at(TownMap.line_point(2, 0.5)), w2.placement_at(TownMap.junction_center(0)), w2.placement_at(TownMap.junction_center(3)), w2.placement_at(TownMap.junction_center(1))],
			"交差点0→交差点2→交差点3→交差点1": [w2.placement_at(TownMap.junction_center(0)), w2.placement_at(TownMap.junction_center(2)), w2.placement_at(TownMap.junction_center(3)), w2.placement_at(TownMap.junction_center(1))],
		}
		for name in order_sets:
			var seq: Array = order_sets[name]
			for sd in SEEDS:
				var idx := [0]
				var times := []
				var pol := func(w, _h):
					if idx[0] < seq.size() and w.funds >= Tuning.SIGNAL_COST:
						var pl: Dictionary = seq[idx[0]]
						var test: Dictionary = w.placement_at(pl.pos)
						if test.ok and w.place_signal_at(test, 0):
							idx[0] += 1
							times.append("%.1f" % w.clock_hours())
							w.waves.clear()
				var r := run_day(pol, sd)
				show("%s 種%d 置いた時刻=%s" % [name, sd, ",".join(times)], r)
	if "--sweep" in args:
		var w0 := TownWorld.new()
		var cands := candidates(w0)
		print("候補数: %d（交差点4 + 路上 %d）" % [cands.size(), cands.size() - 4])
		assert(cands.size() >= 30)
		show("信号なし", run_day(none))
		var res: Array = []
		for c in cands:
			var pl: Dictionary = c[1]
			var pol := func(w, _h):
				if w.signals.is_empty() and w.clock_hours() < 6.01:
					w.place_signal_at(pl, 1)
					w.waves.clear()
			var r := run_day(pol)
			res.append([c[0], r])
			show(c[0], r)
	quit()
