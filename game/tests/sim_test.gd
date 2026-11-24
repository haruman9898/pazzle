extends SceneTree
## ヘッドレス検証: godot --headless --path game --script res://tests/sim_test.gd
## 朝ピークの1ループを、信号なし／信号あり（各プリセット）× 複数の種で回し、
## 接触ゼロ・ゲージの最大値・ヒヤリ・横断歩道の利用を確認する。

const SEEDS := [20261124, 1, 2, 3, 4]

func _check_contacts(w: SimWorld) -> int:
	var n := 0
	for p in w.peds:
		for c in w.cars:
			if c.pos.distance_to(p.pos) > 1.0:
				continue
			if SimWorld._car_rect_dist(c, p.pos) < Tuning.PED_RADIUS - 0.02:
				n += 1
	for i in w.cars.size():
		for j in range(i + 1, w.cars.size()):
			if w.cars[i].pos.distance_to(w.cars[j].pos) < Tuning.CAR_WIDTH * 0.9:
				n += 1
	return n

func _run_one(seed: int, preset: int, verbose: bool) -> Dictionary:
	var w := SimWorld.new()
	w.seed_base = seed
	w.reset_loop()
	if preset >= 0:
		w.place_signal(preset)
	var contacts := 0
	var steps := 0
	var samples := []
	var t0 := Time.get_ticks_msec()
	while w.loop_count == 0:
		w.step(Tuning.SIM_DT)
		steps += 1
		if steps % 3 == 0:
			contacts += _check_contacts(w)
		if verbose and steps % 150 == 0:
			samples.append("%s=%d(c%d,p%d)" % [_hm(w.clock_hours()), int(w.gauge), w.cars.size(), w.peds.size()])
	var r: Dictionary = w.last_loop.duplicate()
	r["contacts"] = contacts
	r["ms"] = float(Time.get_ticks_msec() - t0) / steps
	if verbose:
		print("    seed %d gauge: %s" % [seed, " ".join(samples)])
	return r

func _run(label: String, preset: int) -> void:
	var mg := []
	var hi := 0
	var jw := 0
	var cw := 0
	var ct := 0
	var fo := 0
	var ms := 0.0
	for i in SEEDS.size():
		var r := _run_one(SEEDS[i], preset, i == 0)
		mg.append(r.max_gauge)
		hi += r.hiyari
		jw += r.cross_jay
		cw += r.cross_walk
		ct += r.contacts
		fo += r.forced
		ms += r.ms
	var avg := 0.0
	for x in mg:
		avg += x
	avg /= mg.size()
	var parts := []
	for x in mg:
		parts.append("%d" % int(x))
	var n := SEEDS.size()
	print("[%s] max_gauge avg=%.1f (%s) hiyari/loop=%.1f jaywalk/loop=%.1f crosswalk/loop=%.1f contacts=%d forced=%d sim_ms/step=%.2f" % [
		label, avg, ",".join(parts), float(hi) / n, float(jw) / n, float(cw) / n, ct, fo, ms / n])

func _hm(h: float) -> String:
	return "%d:%02d" % [int(h), int(fmod(h, 1.0) * 60.0)]

func _init() -> void:
	_run("信号なし", -1)
	_run("信号あり・短い", 0)
	_run("信号あり・普通", 1)
	_run("信号あり・長い", 2)
	quit()
