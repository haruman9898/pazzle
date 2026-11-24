class_name Hud
extends CanvasLayer
## 画面 UI（最小限）。ボタン操作はシグナルで main に伝える。
## 上部バー: 時計／不満度ゲージ／ヒヤリ件数／残り資金／速度切替（右上）
## 右下の3本線ボタン → 設置パネル（Coffee Inc方式で右からスライドイン）

signal speed_selected(index: int)
signal menu_pressed
signal menu_closed
signal item_selected(item: String)
signal preset_selected(index: int)
signal place_confirmed
signal place_cancelled
signal popup_preset(index: int)
signal popup_demolish
signal popup_closed
signal home_pressed
signal mode_toggled(is_24h: bool)

const PANEL_W := 390.0
const BAR_H := 68.0

var clock_label: Label
var gauge_bar: ProgressBar
var gauge_label: Label
var hiyari_label: Label
var funds_label: Label
var speed_buttons: Array = []
var debug_label: Label
var paused_label: Label
var menu_button: Button
var home_button: Button
var mode_button: Button
var info_card: PanelContainer
var info_box: VBoxContainer

## 不満の理由: [キー, 表示名, 色]
const CAUSES := [
	["jay", "横断待ち", Color(0.98, 0.6, 0.2)],
	["signal", "信号待ち", Color(0.35, 0.65, 1.0)],
	["jam", "渋滞", Color(0.95, 0.25, 0.25)],
	["delay", "遅れ", Color(0.7, 0.45, 0.95)],
	["hiyari", "ヒヤリ", Color(1.0, 0.9, 0.2)],
	["spread", "周りの不満", Color(0.65, 0.65, 0.7)],
]
var panel: PanelContainer
var panel_funds: Label
var signal_item: Button
var place_bar: PanelContainer
var place_hint: Label
var place_presets: Array = []
var place_cost: Label
var place_confirm: Button
var place_cancel: Button
var popup: PanelContainer
var popup_presets: Array = []
var popup_demolish_btn: Button

var _panel_tween: Tween

func _ready() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	root.theme = _make_theme()
	_build_top_bar(root)
	_build_corner_buttons(root)
	_build_panel(root)
	_build_place_bar(root)
	_build_popup(root)
	_build_info_card(root)
	debug_label = Label.new()
	debug_label.position = Vector2(12, BAR_H + 8)
	debug_label.add_theme_font_size_override("font_size", 22)
	debug_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	debug_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	debug_label.add_theme_constant_override("outline_size", 4)
	debug_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(debug_label)
	paused_label = Label.new()
	paused_label.text = "時間停止中"
	paused_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	paused_label.offset_left = -80
	paused_label.offset_right = 80
	paused_label.offset_top = BAR_H + 70
	paused_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	paused_label.add_theme_color_override("font_color", Color(1, 0.9, 0.3))
	paused_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	paused_label.add_theme_constant_override("outline_size", 5)
	paused_label.visible = false
	paused_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(paused_label)

func _make_theme() -> Theme:
	var th := Theme.new()
	var f = load("res://assets/fonts/ui_font.otf")
	if f:
		th.default_font = f
	th.default_font_size = 24
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.11, 0.13, 0.88)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	th.set_stylebox("panel", "PanelContainer", sb)
	return th

func _build_top_bar(root: Control) -> void:
	var bar := PanelContainer.new()
	bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	bar.offset_bottom = BAR_H
	root.add_child(bar)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 18)
	bar.add_child(hb)
	clock_label = Label.new()
	clock_label.text = "06:00"
	clock_label.add_theme_font_size_override("font_size", 32)
	clock_label.custom_minimum_size = Vector2(100, 0)
	hb.add_child(clock_label)
	var gl := Label.new()
	gl.text = "不満度"
	hb.add_child(gl)
	gauge_bar = ProgressBar.new()
	gauge_bar.custom_minimum_size = Vector2(240, 28)
	gauge_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	gauge_bar.show_percentage = false
	gauge_bar.max_value = 100
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.3, 0.8, 0.4)
	fill.set_corner_radius_all(4)
	gauge_bar.add_theme_stylebox_override("fill", fill)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.25, 0.25, 0.28)
	bg.set_corner_radius_all(4)
	gauge_bar.add_theme_stylebox_override("background", bg)
	hb.add_child(gauge_bar)
	gauge_label = Label.new()
	gauge_label.custom_minimum_size = Vector2(48, 0)
	hb.add_child(gauge_label)
	hiyari_label = Label.new()
	hiyari_label.custom_minimum_size = Vector2(124, 0)
	hb.add_child(hiyari_label)
	funds_label = Label.new()
	funds_label.custom_minimum_size = Vector2(136, 0)
	hb.add_child(funds_label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(spacer)
	var group := ButtonGroup.new()
	for i in Tuning.SPEED_LABELS.size():
		var b := Button.new()
		b.text = Tuning.SPEED_LABELS[i]
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = Vector2(92, 54)
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(func(): speed_selected.emit(i))
		hb.add_child(b)
		speed_buttons.append(b)
	speed_buttons[1].button_pressed = true

func _build_corner_buttons(root: Control) -> void:
	# 右下: 3本線ボタン（設置メニュー）
	menu_button = Button.new()
	menu_button.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	menu_button.offset_left = -116
	menu_button.offset_top = -116
	menu_button.offset_right = -16
	menu_button.offset_bottom = -16
	menu_button.focus_mode = Control.FOCUS_NONE
	root.add_child(menu_button)
	for k in 3:
		var line := ColorRect.new()
		line.color = Color(0.95, 0.95, 0.95)
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.position = Vector2(26, 31 + k * 18)
		line.size = Vector2(48, 7)
		menu_button.add_child(line)
	menu_button.pressed.connect(func(): menu_pressed.emit())
	# 左下: 定位置に戻る
	home_button = Button.new()
	home_button.text = "定位置"
	home_button.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	home_button.offset_left = 16
	home_button.offset_top = -88
	home_button.offset_right = 146
	home_button.offset_bottom = -16
	home_button.focus_mode = Control.FOCUS_NONE
	home_button.pressed.connect(func(): home_pressed.emit())
	root.add_child(home_button)
	# 光の確認用: 朝ピークだけ ⇔ 24時間
	mode_button = Button.new()
	mode_button.text = "朝ピーク"
	mode_button.toggle_mode = true
	mode_button.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	mode_button.offset_left = 160
	mode_button.offset_top = -88
	mode_button.offset_right = 330
	mode_button.offset_bottom = -16
	mode_button.focus_mode = Control.FOCUS_NONE
	mode_button.toggled.connect(func(on):
		mode_button.text = "24時間" if on else "朝ピーク"
		mode_toggled.emit(on))
	root.add_child(mode_button)

func _build_panel(root: Control) -> void:
	panel = PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	panel.offset_left = 0
	panel.offset_right = PANEL_W
	panel.offset_top = BAR_H + 8
	panel.offset_bottom = -8
	panel.visible = false
	root.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	panel.add_child(vb)
	var title := Label.new()
	title.text = "設置"
	title.add_theme_font_size_override("font_size", 32)
	vb.add_child(title)
	panel_funds = Label.new()
	vb.add_child(panel_funds)
	signal_item = Button.new()
	signal_item.custom_minimum_size = Vector2(0, 92)
	signal_item.alignment = HORIZONTAL_ALIGNMENT_LEFT
	signal_item.focus_mode = Control.FOCUS_NONE
	signal_item.pressed.connect(func(): item_selected.emit("signal"))
	vb.add_child(signal_item)
	var desc := Label.new()
	desc.text = "交差点に設置。近くの歩行者は\n横断歩道を使い、車は信号に従う。"
	desc.add_theme_font_size_override("font_size", 19)
	desc.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	vb.add_child(desc)
	var sp := Control.new()
	sp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(sp)
	var close := Button.new()
	close.text = "閉じる（再開）"
	close.custom_minimum_size = Vector2(0, 72)
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(func(): menu_closed.emit())
	vb.add_child(close)

func _build_place_bar(root: Control) -> void:
	place_bar = PanelContainer.new()
	place_bar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	place_bar.offset_left = -470
	place_bar.offset_right = 470
	place_bar.offset_top = -184
	place_bar.offset_bottom = -16
	place_bar.visible = false
	root.add_child(place_bar)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	place_bar.add_child(vb)
	place_hint = Label.new()
	place_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(place_hint)
	var hb := HBoxContainer.new()
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	hb.add_theme_constant_override("separation", 10)
	vb.add_child(hb)
	var il := Label.new()
	il.text = "間隔"
	hb.add_child(il)
	var group := ButtonGroup.new()
	for i in Tuning.SIGNAL_PRESET_LABELS.size():
		var b := Button.new()
		b.text = Tuning.SIGNAL_PRESET_LABELS[i]
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = Vector2(92, 62)
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(func(): preset_selected.emit(i))
		hb.add_child(b)
		place_presets.append(b)
	place_presets[1].button_pressed = true
	place_cost = Label.new()
	place_cost.custom_minimum_size = Vector2(300, 0)
	hb.add_child(place_cost)
	place_confirm = _small_button(hb, "確定", func(): place_confirmed.emit())
	place_cancel = _small_button(hb, "キャンセル", func(): place_cancelled.emit())

func _small_button(parent: Control, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(124, 62)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	parent.add_child(b)
	return b

func _build_popup(root: Control) -> void:
	popup = PanelContainer.new()
	popup.set_anchors_preset(Control.PRESET_CENTER)
	popup.offset_left = -290
	popup.offset_right = 290
	popup.offset_top = -130
	popup.offset_bottom = 130
	popup.visible = false
	root.add_child(popup)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	popup.add_child(vb)
	var t := Label.new()
	t.text = "信号機"
	t.add_theme_font_size_override("font_size", 30)
	vb.add_child(t)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)
	vb.add_child(hb)
	var il := Label.new()
	il.text = "間隔"
	hb.add_child(il)
	var group := ButtonGroup.new()
	for i in Tuning.SIGNAL_PRESET_LABELS.size():
		var b := Button.new()
		b.text = Tuning.SIGNAL_PRESET_LABELS[i]
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = Vector2(104, 62)
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(func(): popup_preset.emit(i))
		hb.add_child(b)
		popup_presets.append(b)
	var hb2 := HBoxContainer.new()
	hb2.add_theme_constant_override("separation", 10)
	vb.add_child(hb2)
	popup_demolish_btn = _small_button(hb2, "取り壊し（+50 返金）", func(): popup_demolish.emit())
	popup_demolish_btn.custom_minimum_size = Vector2(310, 62)
	_small_button(hb2, "閉じる", func(): popup_closed.emit())

# ---- 表示の更新 ----
func update_bar(clock_h: float, gauge: float, hiyari: int, funds: int) -> void:
	clock_label.text = "%02d:%02d" % [int(clock_h), int(fmod(clock_h, 1.0) * 60.0)]
	gauge_bar.value = gauge
	gauge_label.text = "%d" % int(round(gauge))
	var fill: StyleBoxFlat = gauge_bar.get_theme_stylebox("fill")
	fill.bg_color = Color(0.3, 0.8, 0.4).lerp(Color(0.95, 0.25, 0.2), clampf(gauge / 100.0, 0.0, 1.0))
	hiyari_label.text = "ヒヤリ %d" % hiyari
	funds_label.text = "資金 %d" % funds

func open_panel(funds: int, can_signal: bool) -> void:
	panel_funds.text = "残り資金 %d" % funds
	signal_item.text = "  信号機　　費用 %d" % Tuning.SIGNAL_COST
	signal_item.disabled = not can_signal
	panel.visible = true
	if _panel_tween:
		_panel_tween.kill()
	panel.offset_left = 0
	panel.offset_right = PANEL_W
	_panel_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_panel_tween.tween_property(panel, "offset_left", -PANEL_W - 8, 0.25)
	_panel_tween.tween_property(panel, "offset_right", -8, 0.25)

func close_panel() -> void:
	if _panel_tween:
		_panel_tween.kill()
	_panel_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_panel_tween.tween_property(panel, "offset_left", 0.0, 0.2)
	_panel_tween.tween_property(panel, "offset_right", PANEL_W, 0.2)
	_panel_tween.chain().tween_callback(func(): panel.visible = false)

## 配置バーの状態: 0=場所を選ぶ 1=仮配置中（確定するとそのままプレイに戻る）
func show_place_bar(state: int, funds: int, preset: int) -> void:
	place_bar.visible = true
	var pending := state == 1
	for b in place_presets:
		b.disabled = not pending
	place_presets[preset].button_pressed = true
	place_confirm.visible = pending
	place_cancel.visible = true
	place_cancel.text = "キャンセル" if pending else "やめる"
	if pending:
		place_hint.text = "間隔を選んで「確定」"
		place_cost.text = "費用 %d／残り %d→%d" % [Tuning.SIGNAL_COST, funds, funds - Tuning.SIGNAL_COST]
	else:
		place_hint.text = "光っている交差点をタップして仮配置"
		place_cost.text = ""

func hide_place_bar() -> void:
	place_bar.visible = false

func show_popup(preset: int) -> void:
	popup_presets[preset].button_pressed = true
	popup_demolish_btn.text = "取り壊し（+%d 返金）" % int(Tuning.SIGNAL_COST * Tuning.DEMOLISH_REFUND_RATE)
	popup.visible = true

func hide_popup() -> void:
	popup.visible = false

func set_paused(on: bool) -> void:
	paused_label.visible = on
	menu_button.visible = not on


# ---------------------------------------------------------------------
# 停止中だけ表示する情報カード（不満の内訳・選んだ人の理由）
# ---------------------------------------------------------------------
func _build_info_card(root: Control) -> void:
	info_card = PanelContainer.new()
	info_card.set_anchors_preset(Control.PRESET_TOP_LEFT)
	info_card.offset_left = 12
	info_card.offset_top = BAR_H + 128
	info_card.offset_right = 340
	info_card.visible = false
	info_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(info_card)
	info_box = VBoxContainer.new()
	info_box.add_theme_constant_override("separation", 8)
	info_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info_card.add_child(info_box)

func _cause_def(key: String) -> Array:
	for c in CAUSES:
		if c[0] == key:
			return c
	return [key, key, Color.GRAY]

func _lbl(text: String, size := 20, color := Color(1, 1, 1)) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

## totals: 街全体の理由ごとの合計 / picked: 選んだ人 {name, d, cause}（空なら表示しない）
func show_info(totals: Dictionary, picked: Dictionary, can_pick := true) -> void:
	for c in info_box.get_children():
		c.queue_free()
	info_box.add_child(_lbl("いまの不満の内訳", 22))
	var sum := 0.0
	for k in totals:
		sum += totals[k]
	if sum < 0.01:
		info_box.add_child(_lbl("まだ不満はたまっていません", 18, Color(0.8, 0.8, 0.8)))
	else:
		var bar := HBoxContainer.new()
		bar.add_theme_constant_override("separation", 0)
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		for c in CAUSES:
			var v: float = totals.get(c[0], 0.0)
			if v <= 0.0:
				continue
			var r := ColorRect.new()
			r.color = c[2]
			r.custom_minimum_size = Vector2(0, 22)
			r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			r.size_flags_stretch_ratio = maxf(v / sum * 100.0, 1.0)
			r.mouse_filter = Control.MOUSE_FILTER_IGNORE
			bar.add_child(r)
		info_box.add_child(bar)
		for c in CAUSES:
			var v: float = totals.get(c[0], 0.0)
			if v / sum < 0.08:
				continue
			info_box.add_child(_legend_row(c[1], c[2], v / sum, "%d%%" % int(round(v / sum * 100.0))))
	info_box.add_child(_lbl("赤い地面 = 待ちがたまっている", 16, Color(1.0, 0.7, 0.6)))
	if picked.is_empty():
		if can_pick:
			info_box.add_child(_lbl("人をタップすると理由が見られます", 16, Color(0.8, 0.8, 0.8)))
	else:
		info_box.add_child(HSeparator.new())
		info_box.add_child(_lbl("%s　不満 %d" % [picked.name, int(round(picked.d))], 22, Color(1.0, 0.9, 0.3)))
		var cs: Dictionary = picked.cause
		var psum := 0.0
		for k in cs:
			psum += cs[k]
		if psum < 0.01:
			info_box.add_child(_lbl("この人は、いまのところ不満なし", 18, Color(0.8, 0.8, 0.8)))
		else:
			var keys := cs.keys()
			keys.sort_custom(func(a, b): return cs[a] > cs[b])
			for k in keys.slice(0, 3):
				var cd := _cause_def(k)
				info_box.add_child(_legend_row(cd[1], cd[2], cs[k] / psum, "%d%%" % int(round(cs[k] / psum * 100.0))))
	info_card.visible = true

func _legend_row(name: String, color: Color, frac: float, value: String) -> Control:
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sw := ColorRect.new()
	sw.color = color
	sw.custom_minimum_size = Vector2(maxf(frac * 120.0, 8.0), 18)
	sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(sw)
	hb.add_child(_lbl(name, 19))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(sp)
	hb.add_child(_lbl(value, 19, Color(0.85, 0.85, 0.85)))
	return hb

func hide_info() -> void:
	info_card.visible = false
