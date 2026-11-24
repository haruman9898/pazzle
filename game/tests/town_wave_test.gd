extends SceneTree
## 連動（青の波）の確認: 車だけを西端から東端へ一定間隔で流し、
## 2つの交差点（0 と 2）の信号の青のずれを変えて、車の平均停止時間を比べる。
func _run(offset: float, preset: int, linked_mode: bool) -> Array:
	var w := TownWorld.new()
	w.use_schedule = false
	w.through_scale = 0.0
	w.loop_start_h = 7.0
	w.loop_end_h = 200.0
	w.reset_loop()
	w.linking = linked_mode
	var a := w.placement_at(TownMap.junction_center(0))
	w.place_signal_at(a, preset)
	var b := w.placement_at(TownMap.junction_center(2))
	w.place_signal_at(b, preset)
	w.waves.clear()
	var ids := w.signals.keys()
	if not linked_mode:
		w.signals[ids[0]].shift = 0.0
		w.signals[ids[1]].shift = offset
	var acc := 0.0
	var t := 0.0
	while t < 120.0:
		w.step(Tuning.SIM_DT)
		t += Tuning.SIM_DT
		acc += Tuning.SIM_DT
		if acc >= 2.0 and t < 90.0:
			acc = 0.0
			w._spawn_car(100 + 0, 100 + 1, 1)   # 西端（横道 z=-8）→ 東端
	return [w.car_stops_sum / maxf(w.car_done_n, 1), w.car_delay_sum / maxf(w.car_done_n, 1), w.car_done_n,
		w.signals[ids[1]].shift]

func _init() -> void:
	for preset in [1]:
		var C: float = 2.0 * (Tuning.SIGNAL_GREEN[preset] + Tuning.SIGNAL_YELLOW + Tuning.SIGNAL_ALL_RED)
		print("preset=%d 周期=%.1fs。信号2の青のずれ（信号0 = 0）ごとの、車の平均停止時間" % [preset, C])
		var off := 0.0
		while off < C:
			var r := _run(off, preset, false)
			print("  ずれ %.1fs: 停止 %.1fs 遅れ %.1fs 到着 %d" % [off, r[0], r[1], r[2]])
			off += 2.0
		var rl := _run(0.0, preset, true)
		print("  自動連動: 停止 %.1fs 遅れ %.1fs 到着 %d （信号2のずれ=%.1fs）" % [rl[0], rl[1], rl[2], rl[3]])
	quit()
