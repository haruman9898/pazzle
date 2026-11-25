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
	var winsum := {}
	var wincnt := {}
	var win95 := {}
	for k in WINDOWS:
		winmax[k] = 0.0
		winsum[k] = 0.0
		wincnt[k] = 0
		win95[k] = 0
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
				winsum[k] += w.gauge
				wincnt[k] += 1
				if w.gauge >= Tuning.T_GAUGE_LIMIT:
					win95[k] += 1
	var winmean := {}
	var winmin95 := {}
	for k in WINDOWS:
		winmean[k] = winsum[k] / maxf(wincnt[k], 1)
		winmin95[k] = win95[k] * Tuning.SIM_DT * Tuning.CLOCK_RATE / 60.0     # ゲーム内の分
	var r := {"win": winmax, "mean": winmean, "m95": winmin95, "fail": w.fail_reached, "fail_h": w.fail_clock, "contacts": contacts,
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

func _eval_policy(pol: Callable, seeds: Array) -> Dictionary:
	var acc := {"mean": {}, "max": {}, "m95": {}, "fails": 0, "decisions": 0.0, "points": 0, "contacts": 0}
	for k in WINDOWS:
		acc.mean[k] = 0.0
		acc.max[k] = 0.0
		acc.m95[k] = 0.0
	for sd in seeds:
		var r := run_day(pol, sd)
		for k in WINDOWS:
			acc.mean[k] += r.mean[k] / seeds.size()
			acc.max[k] += r.win[k] / seeds.size()
			acc.m95[k] += r.m95[k] / seeds.size()
		if r.fail:
			acc.fails += 1
		acc.decisions += float(r.decisions) / seeds.size()
		acc.points += int(r.funds / seeds.size())
		acc.contacts += r.contacts
	return acc

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

func Tuning_override_red(args: Array) -> void:
	pass

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var none := func(_w, _h): pass
	if "--none" in args:
		for sd in SEEDS:
			show("信号なし 種%d" % sd, run_day(none, sd))
	if "--traj" in args:
		# 無対策／交差点0（短い）／学校前（普通）の、1日の推移（種3つの平均）。--red で赤待ちの遅れペナルティを ON
		Tuning_override_red(args)
		var w3 := TownWorld.new()
		var cases := {"なし": [null, 1], "交差点0 短い": [w3.placement_at(TownMap.junction_center(0)), 0], "学校前 普通": [w3.placement_at(TownMap.line_point(2, 0.5)), 1]}
		var table := {}
		for name in cases:
			var acc := {}
			for sd in SEEDS:
				var pl = cases[name][0]
				var pv: int = cases[name][1]
				var pol := func(w, _h):
					if pl != null and w.signals.is_empty() and w.clock_hours() < 6.01:
						w.place_signal_at(pl, pv)
						w.waves.clear()
				var r := run_day(pol, sd)
				for t in r.traj:
					var hh := int(t[0])
					acc[hh] = acc.get(hh, 0.0) + t[1] / SEEDS.size()
			table[name] = acc
		print("時刻   なし  交差点0短い  学校前普通   （不満度。種3つの平均）")
		for hh in range(6, 31):
			print("%4d  %4d  %8d  %8d" % [hh % 24, table["なし"].get(hh, 0), table["交差点0 短い"].get(hh, 0), table["学校前 普通"].get(hh, 0)])
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
			var mean := {"朝": 0.0, "昼": 0.0, "夕": 0.0, "夜": 0.0}
			var m95 := {"朝": 0.0, "昼": 0.0, "夕": 0.0, "夜": 0.0}
			var fails := 0
			var pts := 0
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
					mean[k] += r.mean[k]
					m95[k] += r.m95[k]
				pts += r.funds
				if r.fail:
					fails += 1
			var n := float(SEEDS.size())
			var line := "[%s]" % name
			for k in tot:
				line += " %s:平均%d/最大%d/上限%d分" % [k, mean[k] / n, tot[k] / n, m95[k] / n]
			print("%s 失敗%d/%d 終了時ポイント%d" % [line, fails, SEEDS.size(), pts / SEEDS.size()])
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
				show("%s 種%d 置いた時刻=%s 決定=%d" % [name, sd, ",".join(times), r.decisions], r)
	if "--one" in args:
		# 1基だけ置いて、あとは何もしない（開発ポイントを使わない）
		var seeds5b := [Tuning.T_SEED, 11, 22, 33, 44]
		var w5 := TownWorld.new()
		var cases1 := {"交差点0 短い": [w5.placement_at(TownMap.junction_center(0)), 0], "交差点0 普通": [w5.placement_at(TownMap.junction_center(0)), 1], "学校前 普通": [w5.placement_at(TownMap.line_point(2, 0.5)), 1], "交差点2 短い": [w5.placement_at(TownMap.junction_center(2)), 0]}
		for name in cases1:
			var pl: Dictionary = cases1[name][0]
			var pv: int = cases1[name][1]
			var pol1 := func(w, _h):
				if w.signals.is_empty() and w.clock_hours() < 6.01:
					w.place_signal_at(pl, pv)
					w.waves.clear()
			var r: Dictionary = _eval_policy(pol1, seeds5b)
			var line := "[1基のみ %s]" % name
			for k in WINDOWS:
				line += " %s:%d/%d/%d" % [k, r.mean[k], r.max[k], r.m95[k]]
			print("%s 失敗%d/5 終了時ポイント%d" % [line, r.fails, r.points])
	if "--policy" in args:
		# 置きっぱなし（最良）と、山ごとに判断し直す疑似プレイヤーを、信号なしと比べる（種5つ）
		var seeds5 := [Tuning.T_SEED, 11, 22, 33, 44]
		var w4 := TownWorld.new()
		var J := func(j, guard := false): return w4.placement_at(TownMap.junction_center(j), guard)
		var school_guard: Dictionary = w4.placement_at(TownMap.line_point(2, 0.5), true)
		var school_sig: Dictionary = w4.placement_at(TownMap.line_point(2, 0.5), false)
		# 置きっぱなし: 決めた順に、100たまるたびに置く。一度置いたら触らない
		var statics := {
			"置きっぱなしA 交差点0→2→3": [J.call(0), J.call(2), J.call(3)],
			"置きっぱなしB 交差点0→3→2": [J.call(0), J.call(3), J.call(2)],
			"置きっぱなしC 交差点0→学校前→2": [J.call(0), school_sig, J.call(2)],
		}
		var results := {}
		results["なし"] = _eval_policy(func(w, _h): pass, seeds5)
		for name in statics:
			var seq: Array = statics[name]
			var pol_s := func(w, _h):
				var idx: int = w.get_meta("idx", 0)
				if idx < seq.size() and w.funds >= Tuning.SIGNAL_COST:
					var t: Dictionary = w.placement_at((seq[idx] as Dictionary).pos)
					if t.ok and w.place_signal_at(t, 0):
						w.set_meta("idx", idx + 1)
						w.waves.clear()
			results[name] = _eval_policy(pol_s, seeds5)
		# 判断し直す: 6時に交差点0、50たまったら学校前に誘導員、昼に交差点2・3、夜（20.5時）に信号を撤去
		var pol_a := func(w, _h):
			var h: float = w.clock_hours()
			if h >= 6.0 and not w.has_meta("j0"):
				var t0: Dictionary = w.placement_at(TownMap.junction_center(0))
				if t0.ok and w.place_signal_at(t0, 0):
					w.set_meta("j0", true)
					w.waves.clear()
			if h < 15.0 and not w.has_meta("guard") and w.funds >= Tuning.GUARD_COST:
				var tg: Dictionary = w.placement_at(TownMap.line_point(2, 0.5), true)
				if tg.ok and w.place_signal_at(tg, 1):
					w.set_meta("guard", true)
			if h >= 10.0 and h < 20.0 and not w.has_meta("j2") and w.funds >= Tuning.SIGNAL_COST:
				var t2: Dictionary = w.placement_at(TownMap.junction_center(2))
				if t2.ok and w.place_signal_at(t2, 0):
					w.set_meta("j2", true)
					w.waves.clear()
			if h >= 12.0 and h < 20.0 and not w.has_meta("j3") and w.funds >= Tuning.SIGNAL_COST:
				var t3: Dictionary = w.placement_at(TownMap.junction_center(3))
				if t3.ok and w.place_signal_at(t3, 0):
					w.set_meta("j3", true)
					w.waves.clear()
			if h >= 20.5 and not w.has_meta("night"):
				w.set_meta("night", true)
				for id in w.signals.keys():
					if not w.signals[id].get("guard", false):
						w.demolish_signal(id)
		results["判断し直す"] = _eval_policy(pol_a, seeds5)
		print("--- 種5つの平均（朝6.5-10／昼10-15／夕15-20／夜20-30。平均/最大/上限にいた分）---")
		for name in results:
			var r: Dictionary = results[name]
			var line := "[%s]" % name
			for k in WINDOWS:
				line += " %s:%d/%d/%d" % [k, r.mean[k], r.max[k], r.m95[k]]
			print("%s 失敗%d/5 決定%.1f 終了時ポイント%d 接触%d" % [line, r.fails, r.decisions, r.points, r.contacts])
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
