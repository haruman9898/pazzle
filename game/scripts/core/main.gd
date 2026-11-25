extends Node3D
## グレーボックス試作のエントリ。シム・表示・UI・入力をつなぐ。
## 状態: PLAY（時間が進む）/ MENU（設置パネル）/ PLACE（配置）/ POPUP（設備）
## PLAY 以外では時間が止まる（仕様 3章）。

enum State { PLAY, MENU, PLACE, POPUP, RESULT }

const TAP_MAX_MOVE := 12.0      # これ以下の移動で離せばタップ
const LONG_PRESS := 0.35        # 長押し判定（秒）。長押し後のドラッグ = 回転

var town := true                # ステージ1（交差点4つ）。URL に ?map=legacy を付けると、1交差点の旧マップ
var debug := false              # URL に ?debug=1 を付けると、確認用のボタン（24時間・雨）を出す
var sim                         # SimWorld（1交差点）または TownWorld（ステージ1）
var view                        # WorldView または TownView
var popup_id := -1              # 設備ポップアップで開いている信号
var pending: Dictionary = {}    # 仮配置の場所
var agents: AgentsView
var raining := false
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
var _sim_ms := 0.0             # 1フレームあたりのシム処理時間（ms、平滑化）

# 入力
var _touches := {}              # index -> 位置
var _t_start_pos := Vector2.ZERO
var _t_start_time := 0.0
var _t_mode := ""               # "", "pending", "pan", "rotate", "pinch"
var _pinch_dist := 0.0
var _rmb := false

## 町の地図の立ち話の場所 [x, z, 向き, 開始時刻, 終了時刻]（建物の外の芝生の縁）
const TOWN_CHAT := [
	[-11.5, -8.5, 1, 6.0, 21.0], [0.5, -8.5, 1, 9.0, 17.0], [11.5, -8.5, 1, 6.5, 20.5], [-8.5, 0.5, 0, 9.5, 17.0],
	[8.5, -2.5, 0, 17.0, 21.0], [-11.5, 8.5, 1, 9.5, 17.0], [0.5, 8.5, 1, 10.0, 16.5], [11.5, 8.5, 1, 17.5, 20.5],
]

func _ready() -> void:
	var map_param = null
	var debug_param = null
	if OS.has_feature("web"):
		map_param = JavaScriptBridge.eval("new URLSearchParams(window.location.search).get('map')")
		debug_param = JavaScriptBridge.eval("new URLSearchParams(window.location.search).get('debug')")
	town = not (map_param != null and str(map_param) == "legacy")
	debug = debug_param != null and str(debug_param) == "1"
	sim = TownWorld.new() if town else SimWorld.new()
	if town:
		sim.auto_loop = false
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
	view = TownView.new() if town else WorldView.new()
	add_child(view)
	view.setup(sim)
	agents = AgentsView.new()
	add_child(agents)
	agents.setup(sim)
	rig = CameraRig.new()
	add_child(rig)
	if town:
		rig.configure(22.0, 34.0, 10.0)
		agents.configure(20.0, TOWN_CHAT)
	hud = Hud.new()
	add_child(hud)
	hud.speed_selected.connect(func(i): speed_index = i)
	hud.menu_pressed.connect(_open_menu)
	hud.menu_closed.connect(_close_menu)
	hud.item_selected.connect(_on_item)
	hud.preset_selected.connect(func(i): place_preset = i)
	hud.place_confirmed.connect(_confirm_place)
	hud.place_cancelled.connect(_cancel_place)
	hud.popup_preset.connect(func(i): sim.set_preset(popup_id, i))
	if town:
		hud.hint_pick = "光っている道路をタップして仮配置"
	hud.popup_demolish.connect(_demolish)
	hud.popup_closed.connect(_close_popup)
	hud.home_pressed.connect(func(): rig.go_home())
	hud.result_pressed.connect(_retry)
	hud.mode_button.visible = debug
	hud.rain_button.visible = debug
	hud.auto_note.visible = town
	hud.mode_toggled.connect(_on_mode_toggled)
	hud.rain_toggled.connect(_on_rain_toggled)
	_build_light_keys()
	_read_url_params()

func _process(delta: float) -> void:
	if state == State.PLAY and town and (sim.fail_reached or sim.day_over):
		_show_result()
	if state == State.PLAY:
		var mult: float = Tuning.SPEED_MULTS[speed_index]
		_acc += delta * mult
		var n := 0
		var t0 := Time.get_ticks_usec()
		while _acc >= Tuning.SIM_DT and n < 8:
			if town:
				sim.step(Tuning.SIM_DT, Tuning.SIM_DT / mult)
			else:
				sim.step(Tuning.SIM_DT)
			_acc -= Tuning.SIM_DT
			n += 1
		if n == 8:
			_acc = 0.0
		_sim_ms = lerpf(_sim_ms, (Time.get_ticks_usec() - t0) / 1000.0, 0.1)
	var hour := fposmod(sim.clock_hours(), 24.0)
	hud.update_bar(hour, sim.gauge, sim.hiyari_total, sim.funds)
	var stopped := state == State.MENU or state == State.PLACE
	if stopped != _was_stopped:
		_was_stopped = stopped
		view.set_heat_visible(stopped)
		if stopped:
			hud.show_info(sim.cause_totals())
		else:
			hud.hide_info()
	_apply_light(hour)
	hud.set_paused(state != State.PLAY and state != State.RESULT)
	if state == State.RESULT:
		hud.menu_button.visible = false
		hud.paused_label.visible = false
	_update_debug()

## クリア／失敗の結果（第1回は簡易。第3回で★・事後診断・ダイジェストまで一続きにする）
func _show_result() -> void:
	state = State.RESULT
	_close_overlays()
	var lines: Array = []
	var title := "クリア！"
	if sim.fail_reached:
		title = "失敗…"
		var fh := fposmod(sim.fail_clock, 24.0)
		lines.append("%d:%02d ごろ、%s で、不満が上限に達しました" % [int(fh), int(fmod(fh, 1.0) * 60.0), _place_name(sim.fail_pos)])
		lines.append("そのまま2時間、上限が続きました")
	else:
		lines.append("24時間を、乗り切りました")
	lines.append("最大の不満度 %d ／ ヒヤリ %d 件" % [int(sim.max_gauge), sim.hiyari_total])
	lines.append("開発ポイント %d（バブル %d 個を回収）" % [sim.funds, sim.bubble_stats.collected])
	hud.show_result(title, lines, "もう一度（速度はそのまま）")

func _close_overlays() -> void:
	hud.hide_popup()
	hud.hide_place_bar()
	hud.close_panel()
	view.set_ghost(false)
	view.set_highlight(false)

## 同じステージを最初から。速度設定（speed_index）は変えない
func _retry() -> void:
	hud.hide_result()
	sim.restart()
	state = State.PLAY

func _place_name(p: Vector2) -> String:
	var jp := {"home": "住宅", "shop": "商店", "office": "オフィス", "school": "小学校"}
	var best := "街"
	var bd := 1e9
	for b in TownMap.BUILDINGS:
		var d: float = (b.door as Vector2).distance_to(p)
		if d < bd:
			bd = d
			best = jp[b.type] + "の前"
	for j in 4:
		var d2: float = TownMap.junction_center(j).distance_to(p) - 2.0
		if d2 < bd:
			bd = d2
			best = "交差点"
	return best

func _update_debug() -> void:
	var t := ("ステージ1 " if town else "") + "FPS %d | シム %.1fms 描画更新 %.1fms | 車 %d / 歩行者 %d | 横断: 無断 %d / 横断歩道 %d | 上限継続 %d分%s" % [
		Engine.get_frames_per_second(), _sim_ms, agents.update_ms, sim.cars.size(), sim.peds.size(),
		sim.cross_jay, sim.cross_walk, int(sim.over_limit_game_s / 60.0),
		"（失敗条件に到達）" if sim.fail_reached else ""]
	if not sim.last_loop.is_empty():
		var l: Dictionary = sim.last_loop
		t += "\n前回ループ（%s）: 最大不満度 %d / ヒヤリ %d / 無断横断 %d / 横断歩道 %d" % [
			"信号あり" if l.signal else "信号なし", int(l.max_gauge), l.hiyari, l.cross_jay, l.cross_walk]
	if town:
		t += "\n1日: 6:00〜翌6:00　/　決定 %d 回　/　バブル 出%d 回収%d 逃%d" % [sim.decisions, sim.bubble_stats.spawned, sim.bubble_stats.collected, sim.bubble_stats.missed]
	else:
		t += "\n試作ループ: %d:00〜%d:00 を繰り返し（第%d回）" % [int(sim.loop_start_h), int(sim.loop_end_h), sim.loop_count + 1]
	hud.debug_label.text = t

# ---------------------------------------------------------------------
# 状態遷移
# ---------------------------------------------------------------------
func _open_menu() -> void:
	if state != State.PLAY:
		return
	state = State.MENU
	hud.open_panel(sim.funds, sim.can_place())
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
	var pl: Dictionary = sim.placement_at(ground)
	if pl.get("ok", false):
		pending = pl
		place_state = 1
		view.set_ghost(true, pl)
		view.set_highlight(false)
		hud.show_place_bar(place_state, sim.funds, place_preset)

func _confirm_place() -> void:
	if place_state != 1:
		return
	if sim.place_signal_at(pending, place_preset):
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
	hud.show_popup(sim.preset_of(popup_id))

func _demolish() -> void:
	sim.demolish(popup_id)
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
			popup_id = sim.signal_at(g)
			if popup_id >= 0:
				_open_popup()

## URL で開始時刻と天気を指定できる（確認・共有用）。例: ?t=12  ?t=17.5&rain=1
## t = 開始時刻（0〜24。24時間表示になる）、rain=1 で雨
func _read_url_params() -> void:
	if not OS.has_feature("web"):
		return
	var t = JavaScriptBridge.eval("new URLSearchParams(window.location.search).get('t')")
	var r = JavaScriptBridge.eval("new URLSearchParams(window.location.search).get('rain')")
	if t != null and str(t).is_valid_float():
		hud.mode_button.button_pressed = true
		sim.clock_s = clampf(float(str(t)), 0.0, 23.99) * 3600.0
	if r != null and str(r) == "1":
		hud.rain_button.button_pressed = true
	# 結果画面の確認用（?debug=1&result=fail / clear）
	var res = JavaScriptBridge.eval("new URLSearchParams(window.location.search).get('result')")
	if debug and town and res != null:
		if str(res) == "fail":
			sim.fail_reached = true
			sim.fail_clock = 9.0
			sim.fail_pos = Vector2(-6.0, 0.5)
		elif str(res) == "clear":
			sim.day_over = true

func _on_rain_toggled(on: bool) -> void:
	raining = on
	agents.set_raining(on)
	view.set_wet(on)

func _on_mode_toggled(is_24h: bool) -> void:
	var s0 := Tuning.T_LOOP_START if town else Tuning.LOOP_START_H
	var e0 := Tuning.T_LOOP_END if town else Tuning.LOOP_END_H
	sim.loop_start_h = 0.0 if is_24h else s0
	sim.loop_end_h = 24.0 if is_24h else e0
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
	var energy := lerpf(a[4], b[4], t)
	var sun_col: Color = (a[3] as Color).lerp(b[3], t)
	var amb_col: Color = (a[5] as Color).lerp(b[5], t)
	var amb_e: float = lerpf(a[6], b[6], t)
	var bg: Color = (a[7] as Color).lerp(b[7], t)
	if raining:
		# 雨の日は、光が弱く灰色がかる（見た目だけ）
		var gray := Color(0.42, 0.45, 0.5) * clampf(bg.get_luminance() * 2.4, 0.2, 1.0)
		sun_col = sun_col.lerp(Color(0.7, 0.72, 0.78), 0.6)
		energy *= 0.55
		amb_col = amb_col.lerp(Color(0.6, 0.62, 0.68), 0.5)
		amb_e += 0.2
		bg = bg.lerp(gray, 0.7)
	sun.light_color = sun_col
	sun.light_energy = energy
	environment.ambient_light_color = amb_col
	environment.ambient_light_energy = amb_e
	environment.background_color = bg
	var dark := 1.0 - clampf((energy - 0.3) / 0.5, 0.0, 1.0)
	if raining:
		dark = maxf(dark, 0.0)
	view.set_night(dark)
	agents.night = dark
	agents.hour = h

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
