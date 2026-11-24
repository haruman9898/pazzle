extends SceneTree
## ステージ1（交差点4つ）のヘッドレス検証
## godot --headless --script res://tests/town_test.gd
## 朝ピークの1ループを回し、接触ゼロ・止まり続けた最長時間・ゲージ・到着数を確認する。

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
			if w.cars[i].pos.distance_to(w.cars[j].pos) < Tuning.CAR_WIDTH * 0.9:
				n += 1
	return n

## placements: 置く信号 [{placement, preset}]。戻り値は1ループの結果
func run(placements: Array, verbose := false, seed := Tuning.T_SEED, end_h := Tuning.T_LOOP_END, linking := true) -> Dictionary:
	var w := TownWorld.new()
	w.linking = linking
	w.seed_base = seed
	w.loop_end_h = end_h
	w.reset_loop()
	for pl in placements:
		w.place_signal_at(pl[0], pl[1])
	w.waves.clear()
	var contacts := 0
	var steps := 0
	var peak := 0
	var samples := []
	var t0 := Time.get_ticks_msec()
	while w.loop_count == 0:
		w.step(Tuning.SIM_DT)
		steps += 1
		if steps % 3 == 0:
			contacts += _contacts(w)
		peak = maxi(peak, w.cars.size() + w.peds.size())
		if verbose and steps % 120 == 0:
			samples.append("%d:%02d=%d(c%d,p%d)" % [int(w.clock_hours()), int(fmod(w.clock_hours(), 1.0) * 60.0), int(w.gauge), w.cars.size(), w.peds.size()])
	var r: Dictionary = w.last_loop.duplicate()
	r["contacts"] = contacts
	r["peak"] = peak
	r["ms"] = float(Time.get_ticks_msec() - t0) / steps
	r["left_cars"] = w.cars.size()
	r["left_peds"] = w.peds.size()
	if verbose:
		print("    gauge: ", " ".join(samples))
	return r

func fmt(label: String, r: Dictionary) -> void:
	print("[%s] max_gauge=%.1f hiyari=%d jay=%d cw=%d contacts=%d forced=%d max_stop=%.1fs trips=%d car_delay=%.1fs car_stop=%.1fs peak=%d ms=%.2f" % [
		label, r.max_gauge, r.hiyari, r.cross_jay, r.cross_walk, r.contacts, r.forced, r.max_stop, r.trips, r.car_delay, r.car_stop, r.peak, r.ms])

func _candidates(w: TownWorld) -> Array:
	var out: Array = []
	for j in 4:
		out.append(["交差点%d" % j, w.placement_at(TownMap.junction_center(j))])
	for l in 4:
		for t in [-15.5, -13.5, -2.5, -0.5, 1.5, 2.5, 13.5, 15.5]:
			var g := TownMap.line_point(l, t)
			var pl := w.placement_at(g)
			if pl.ok:
				out.append(["路上 線%d t=%.1f" % [l, t], pl])
	return out

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var w0 := TownWorld.new()
	if "--sweep" in args:
		var r0 := run([], true)
		fmt("信号なし", r0)
		var res: Array = []
		for c in _candidates(w0):
			var r := run([[c[1], 1]])
			res.append([r.max_gauge, c[0], r])
		res.sort_custom(func(a, b): return a[0] < b[0])
		print("--- 1基だけ置いたとき（普通）。良い順 ---")
		for x in res:
			fmt(x[1], x[2])
	if "--link" in args:
		# 連動のオン・オフ比較（複数の種の平均）。2基・3基を同じ道路上に置く
		var jc := func(j): return w0.placement_at(TownMap.junction_center(j))
		var sets := {
			"交差点0+2（横道z=-8）": [jc.call(0), jc.call(2)],
			"交差点1+3（横道z=8）": [jc.call(1), jc.call(3)],
			"交差点0+2+3": [jc.call(0), jc.call(2), jc.call(3)],
		}
		var seeds := [Tuning.T_SEED, 11, 22, 33, 44]
		for name in sets:
			var pls: Array = []
			for pl in sets[name]:
				pls.append([pl, 1])
			for mode in [true, false]:
				var g := 0.0
				var cd := 0.0
				var cs := 0.0
				for sd in seeds:
					var r := run(pls, false, sd, Tuning.T_LOOP_END, mode)
					g += r.max_gauge
					cd += r.car_delay
					cs += r.car_stop
				print("[%s %s] 平均: max_gauge=%.1f car_delay=%.1fs car_stop=%.1fs" % [name, "連動あり" if mode else "連動なし", g / seeds.size(), cd / seeds.size(), cs / seeds.size()])
	quit()
