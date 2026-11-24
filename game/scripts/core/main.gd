extends Node3D
## グレーボックス試作のエントリ。シム・表示・UI・入力をつなぐ。
## 状態: PLAY（時間が進む）/ MENU（設置パネル）/ PLACE（配置）/ POPUP（設備）
## PLAY 以外では時間が止まる（仕様 3章）。

enum State { PLAY, MENU, PLACE, POPUP }

const TAP_MAX_MOVE := 12.0      # これ以下の移動で離せばタップ
const LONG_PRESS := 0.35        # 長押し判定（秒）。長押し後のドラッグ = 回転

var sim := SimWorld.new()
var view: WorldView
var rig: CameraRig
var hud: Hud
var state := State.PLAY
var speed_index := 1
var place_state := 0            # 0=場所を選ぶ 1=仮配置中（確定したらそのままプレイに戻る）
var place_preset := 1
var _acc := 0.0
var environment: Environment
var sun: DirectionalLight3D
var _light_keys: Array = []
var _was_stopped := false
var picked = null               # 停止中に選んだ人
var _sim_ms := 0.0             # 1フレームあたりのシム処理時間（ms、平滑化）

# 入力
var _touches := {}              # index -> 位置
var _t_start_pos := Vector2.ZERO
var _t_start_time := 0.0
var _t_mode := ""               # "", "pending", "pan", "rotate", "pinch"
var _pinch_dist := 0.0
var _rmb := false

func _ready() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	environment = e
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.16, 0.18, 0.2)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.7, 0.72, 0.78)
	e.ambient_light_energy = 0.35
	env.environment = e
	add_child(env)
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 35, 0)
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	add_child(sun)
	view = WorldView.new()
	add_child(view)
	view.setup(sim)
	rig = CameraRig.new()
	add_child(rig)
	hud = Hud.new()
	add_child(hud)
	hud.speed_selected.connect(func(i): speed_index = i)
	hud.menu_pressed.connect(_open_menu)
	hud.menu_closed.connect(_close_menu)
	hud.item_selected.connect(_on_item)
	hud.preset_selected.connect(func(i): place_preset = i)
	hud.place_confirmed.connect(_confirm_place)
	hud.place_cancelled.connect(_cancel_place)
	hud.popup_preset.connect(func(i): sim.set_signal_preset(i))
	hud.popup_demolish.connect(_demolish)
	hud.popup_closed.connect(_close_popup)
	hud.home_pressed.connect(func(): rig.go_home())
	hud.mode_toggled.connect(_on_mode_toggled)
	_build_light_keys()

func _process(delta: float) -> void:
	if state == State.PLAY:
		_acc += delta * Tuning.SPEED_MULTS[speed_index]
		var n := 0
		var t0 := Time.get_ticks_usec()
		while _acc >= Tuning.SIM_DT and n < 8:
			sim.step(Tuning.SIM_DT)
			_acc -= Tuning.SIM_DT
			n += 1
		if n == 8:
			_acc = 0.0
		_sim_ms = lerpf(_sim_ms, (Time.get_ticks_usec() - t0) / 1000.0, 0.1)
	hud.update_bar(sim.clock_hours(), sim.gauge, sim.hiyari_total, sim.funds)
	var stopped := state == State.MENU or state == State.PLACE
	if stopped != _was_stopped:
		_was_stopped = stopped
		view.set_heat_visible(stopped)
		picked = null
		view.selected = null
		if stopped:
			hud.show_info(sim.cause_totals(), {}, state == State.MENU)
		else:
			hud.hide_info()
	_apply_light(sim.clock_hours())
	hud.set_paused(state != State.PLAY)
	_update_debug()

func _update_debug() -> void:
	var t := "FPS %d | シム %.1fms | 車 %d / 歩行者 %d | 横断: 無断 %d / 横断歩道 %d | 上限継続 %d分%s" % [
		Engine.get_frames_per_second(), _sim_ms, sim.cars.size(), sim.peds.size(),
		sim.cross_jay, sim.cross_walk, int(sim.over_limit_game_s / 60.0),
		"（失敗条件に到達）" if sim.fail_reached else ""]
	if not sim.last_loop.is_empty():
		var l := sim.last_loop
		t += "\n前回ループ（%s）: 最大不満度 %d / ヒヤリ %d / 無断横断 %d / 横断歩道 %d" % [
			"信号あり" if l.signal else "信号なし", int(l.max_gauge), l.hiyari, l.cross_jay, l.cross_walk]
	t += "\n試作ループ: %d:00〜%d:00 を繰り返し（第%d回）" % [int(sim.loop_start_h), int(sim.loop_end_h), sim.loop_count + 1]
	hud.debug_label.text = t

# ---------------------------------------------------------------------
# 状態遷移
# ---------------------------------------------------------------------
func _open_menu() -> void:
	if state != State.PLAY:
		return
	state = State.MENU
	hud.open_panel(sim.funds, not sim.signal_on and sim.funds >= Tuning.SIGNAL_COST)
	rig.shift_for_panel(Hud.PANEL_W)

func _close_menu() -> void:
	hud.close_panel()
	rig.shift_for_panel(0.0)
	state = State.PLAY

func _on_item(item: String) -> void:
	if item != "signal":
		return
	hud.close_panel()
	rig.shift_for_panel(0.0)
	state = State.PLACE
	hud.show_info(sim.cause_totals(), {}, false)
	picked = null
	view.selected = null
	place_state = 0
	place_preset = 1
	view.set_highlight(true)
	view.set_ghost(false)
	hud.show_place_bar(place_state, sim.funds, place_preset)

func _on_place_tap(ground: Vector2) -> void:
	if WorldView.hits_intersection(ground):
		place_state = 1
		view.set_ghost(true)
		view.set_highlight(false)
		hud.show_place_bar(place_state, sim.funds, place_preset)

func _confirm_place() -> void:
	if place_state != 1:
		return
	if sim.place_signal(place_preset):
		_finish_place()

## 仮配置の取り消し。仮配置中なら場所選びに戻り、場所選びのときは設置をやめてプレイに戻る。
func _cancel_place() -> void:
	if place_state == 1:
		place_state = 0
		view.set_ghost(false)
		view.set_highlight(true)
		hud.show_place_bar(place_state, sim.funds, place_preset)
	else:
		_finish_place()

func _finish_place() -> void:
	view.set_ghost(false)
	view.set_highlight(false)
	hud.hide_place_bar()
	state = State.PLAY

func _open_popup() -> void:
	state = State.POPUP
	hud.show_popup(sim.signal_preset)

func _demolish() -> void:
	sim.demolish_signal()
	_close_popup()

func _close_popup() -> void:
	hud.hide_popup()
	state = State.PLAY

func _on_tap(screen: Vector2) -> void:
	var g = rig.screen_to_ground(screen)
	if g == null:
		return
	# 設置パネルを開いている間は、人をタップするとその人の不満の理由を表示する
	# （配置中は、交差点のタップを配置に使うため、人の選択は行わない）
	if state == State.MENU:
		var a = _pick_agent(g)
		if a != null:
			picked = a
			view.selected = a
			hud.show_info(sim.cause_totals(), {"name": "車" if a.kind == SimWorld.KIND_CAR else "歩行者", "d": a.d, "cause": a.cause})
			return
	match state:
		State.PLACE:
			_on_place_tap(g)
		State.PLAY:
			if sim.signal_on and WorldView.hits_intersection(g):
				_open_popup()

func _pick_agent(g: Vector2):
	var best = null
	var bd := 0.75
	for c in sim.cars:
		var d: float = c.pos.distance_to(g)
		if d < bd:
			bd = d
			best = c
	for p in sim.peds:
		var d: float = p.pos.distance_to(g) - 0.15   # 歩行者は小さいので少し選びやすくする
		if d < bd:
			bd = d
			best = p
	return best

func _on_mode_toggled(is_24h: bool) -> void:
	sim.loop_start_h = 0.0 if is_24h else Tuning.LOOP_START_H
	sim.loop_end_h = 24.0 if is_24h else Tuning.LOOP_END_H
	sim.reset_loop()

# ---------------------------------------------------------------------
# 時間帯による光の変化（朝＝柔らかい／昼＝明るい／夕＝オレンジ／夜＝月明かりと街灯）
# ---------------------------------------------------------------------
func _build_light_keys() -> void:
	# [時刻, 太陽の仰角, 向き, 太陽の色, 強さ, 環境光の色, 環境光の強さ, 背景色]
	var night := [Color(0.45, 0.55, 0.9), 0.3, Color(0.3, 0.36, 0.6), 0.65, Color(0.06, 0.08, 0.17)]
	_light_keys = [
		[0.0, -35.0, -60.0] + night,
		[5.0, -35.0, -60.0] + night,
		[6.0, -9.0, 105.0, Color(1.0, 0.62, 0.4), 0.55, Color(0.55, 0.5, 0.6), 0.45, Color(0.42, 0.38, 0.5)],
		[7.5, -28.0, 95.0, Color(1.0, 0.85, 0.7), 0.85, Color(0.7, 0.7, 0.78), 0.4, Color(0.5, 0.58, 0.72)],
		[12.0, -68.0, 20.0, Color(1.0, 0.98, 0.95), 1.1, Color(0.75, 0.78, 0.85), 0.4, Color(0.45, 0.62, 0.85)],
		[16.0, -38.0, -50.0, Color(1.0, 0.92, 0.8), 1.0, Color(0.72, 0.72, 0.8), 0.4, Color(0.5, 0.62, 0.8)],
		[17.5, -10.0, -85.0, Color(1.0, 0.55, 0.3), 0.8, Color(0.65, 0.5, 0.5), 0.4, Color(0.6, 0.4, 0.35)],
		[18.5, -5.0, -80.0, Color(0.8, 0.4, 0.45), 0.4, Color(0.4, 0.35, 0.5), 0.4, Color(0.25, 0.2, 0.35)],
		[20.0, -35.0, -60.0] + night,
		[24.0, -35.0, -60.0] + night,
	]

func _apply_light(h: float) -> void:
	var i := 0
	while i < _light_keys.size() - 2 and h >= _light_keys[i + 1][0]:
		i += 1
	var a: Array = _light_keys[i]
	var b: Array = _light_keys[i + 1]
	var t := clampf((h - a[0]) / maxf(b[0] - a[0], 0.0001), 0.0, 1.0)
	sun.rotation_degrees = Vector3(lerpf(a[1], b[1], t), lerpf(a[2], b[2], t), 0.0)
	sun.light_color = (a[3] as Color).lerp(b[3], t)
	var energy := lerpf(a[4], b[4], t)
	sun.light_energy = energy
	environment.ambient_light_color = (a[5] as Color).lerp(b[5], t)
	environment.ambient_light_energy = lerpf(a[6], b[6], t)
	environment.background_color = (a[7] as Color).lerp(b[7], t)
	view.set_night(1.0 - clampf((energy - 0.3) / 0.5, 0.0, 1.0))

# ---------------------------------------------------------------------
# 入力: 1本指ドラッグ = 移動 / 1本指長押し→ドラッグ = 回転 / 2本指 = ズーム
# マウス: 左ドラッグ = 移動 / 右ドラッグ = 回転 / ホイール = ズーム（左長押し→ドラッグでも回転）
# ---------------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_on_touch(event)
	elif event is InputEventScreenDrag:
		_on_drag(event)
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			rig.zoom_by(0.9)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			rig.zoom_by(1.1)
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			_rmb = mb.pressed
	elif event is InputEventMouseMotion and _rmb:
		rig.rotate_by_pixels((event as InputEventMouseMotion).relative.x)

func _on_touch(ev: InputEventScreenTouch) -> void:
	if ev.pressed:
		_touches[ev.index] = ev.position
		if _touches.size() == 1:
			_t_start_pos = ev.position
			_t_start_time = Time.get_ticks_msec() / 1000.0
			_t_mode = "pending"
		elif _touches.size() == 2:
			_t_mode = "pinch"
			var ps := _touches.values()
			_pinch_dist = (ps[0] as Vector2).distance_to(ps[1])
	else:
		# 短く押して離した = タップ（長押しして動かさずに離した場合は何もしない）
		if _touches.size() == 1 and _t_mode == "pending" and Time.get_ticks_msec() / 1000.0 - _t_start_time < LONG_PRESS * 2.0:
			_on_tap(ev.position)
		_touches.erase(ev.index)
		if _touches.is_empty():
			_t_mode = ""
		elif _t_mode == "pinch":
			_t_mode = "none"

func _on_drag(ev: InputEventScreenDrag) -> void:
	_touches[ev.index] = ev.position
	match _t_mode:
		"pending":
			# 動き始めた時点で、押してからの時間で判定する: 長押し後なら回転、すぐなら移動
			if ev.position.distance_to(_t_start_pos) > TAP_MAX_MOVE:
				if Time.get_ticks_msec() / 1000.0 - _t_start_time >= LONG_PRESS:
					_t_mode = "rotate"
				else:
					_t_mode = "pan"
					rig.pan_by_pixels(ev.position - _t_start_pos)
		"pan":
			rig.pan_by_pixels(ev.relative)
		"rotate":
			rig.rotate_by_pixels(ev.relative.x)
		"pinch":
			if _touches.size() >= 2:
				var ps := _touches.values()
				var d := (ps[0] as Vector2).distance_to(ps[1])
				if d > 1.0 and _pinch_dist > 1.0:
					rig.zoom_by(_pinch_dist / d)
				_pinch_dist = d
