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
var place_state := 0            # 0=場所を選ぶ 1=仮配置中 2=確定済み
var place_preset := 1
var _acc := 0.0
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
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.16, 0.18, 0.2)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.7, 0.72, 0.78)
	e.ambient_light_energy = 0.35
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
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
	hud.place_finished.connect(_finish_place)
	hud.popup_preset.connect(func(i): sim.set_signal_preset(i))
	hud.popup_demolish.connect(_demolish)
	hud.popup_closed.connect(_close_popup)
	hud.home_pressed.connect(func(): rig.go_home())

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
	t += "\n試作ループ: %d:00〜%d:00 を繰り返し（第%d回）" % [int(Tuning.LOOP_START_H), int(Tuning.LOOP_END_H), sim.loop_count + 1]
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
	place_state = 0
	place_preset = 1
	view.set_highlight(true)
	view.set_ghost(false)
	hud.show_place_bar(place_state, sim.funds, place_preset)

func _on_place_tap(ground: Vector2) -> void:
	if place_state == 2:
		return
	if WorldView.hits_intersection(ground):
		place_state = 1
		view.set_ghost(true)
		view.set_highlight(false)
		hud.show_place_bar(place_state, sim.funds, place_preset)

func _confirm_place() -> void:
	if place_state != 1:
		return
	if sim.place_signal(place_preset):
		place_state = 2
		view.set_ghost(false)
		view.set_highlight(false)
		hud.show_place_bar(place_state, sim.funds, place_preset)

func _cancel_place() -> void:
	place_state = 0
	view.set_ghost(false)
	view.set_highlight(true)
	hud.show_place_bar(place_state, sim.funds, place_preset)

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
	match state:
		State.PLACE:
			_on_place_tap(g)
		State.PLAY:
			if sim.signal_on and WorldView.hits_intersection(g):
				_open_popup()

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
