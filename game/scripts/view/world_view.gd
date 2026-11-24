class_name WorldView
extends Node3D
## 表示（グレーボックス）。SimWorld の状態を読んで箱と色で描く。
## モデル規約: ピボット = footprint の底面中心（地面 y=0）。差し替え時もこの規約を守る。

const MAX_EVENTS := 32

const C_GROUND := Color(0.36, 0.42, 0.34)
const C_ROAD := Color(0.22, 0.22, 0.24)
const C_WALK := Color(0.62, 0.62, 0.6)
const C_LINE := Color(0.85, 0.75, 0.3)
const C_WHITE := Color(0.92, 0.92, 0.92)
const C_CAR := Color(0.45, 0.68, 0.95)
const C_PED := Color(0.97, 0.97, 0.97)
const C_ANGRY := Color(0.95, 0.2, 0.15)
const AREA_COLORS := [Color(0.55, 0.5, 0.42), Color(0.45, 0.52, 0.6), Color(0.6, 0.48, 0.45), Color(0.47, 0.55, 0.45)]

var sim: SimWorld
var _event_mm: MultiMesh
var _signal_root: Node3D
var _ghost_root: Node3D
var _highlight: MeshInstance3D
var _highlight_mat: StandardMaterial3D
var _heat_mm: MultiMesh
var _heat_node: MultiMeshInstance3D
var _wave_ring: MeshInstance3D
var _wave_mat: StandardMaterial3D
var _road_mat: StandardMaterial3D
var _lamp_mats: Array = []
var _pool_mat: StandardMaterial3D
var _car_lamps := {}   # arm -> StandardMaterial3D
var _ped_lamps := {}   # arm -> StandardMaterial3D
var _t := 0.0

func setup(s: SimWorld) -> void:
	sim = s
	_build_static()
	_build_dynamic()
	_build_signal()
	_build_placement()
	_build_extras()

# ---------------------------------------------------------------------
func _mat(color: Color, alpha := 1.0, unshaded := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(color.r, color.g, color.b, alpha)
	if alpha < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if unshaded:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m

## 底面中心ピボットの箱（size = 幅x, 高さy, 奥行z）
func _box(parent: Node3D, size: Vector3, center_xz: Vector2, y0: float, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = Vector3(center_xz.x, y0 + size.y * 0.5, center_xz.y)
	parent.add_child(mi)
	return mi

func _build_static() -> void:
	var L := Tuning.ARM_LEN
	var root := Node3D.new()
	root.name = "Static"
	add_child(root)
	_box(root, Vector3(L * 2 + 4, 0.1, L * 2 + 4), Vector2.ZERO, -0.1, _mat(C_GROUND))
	# 四隅の発生・吸収エリア（住宅・学校・オフィスの代わり）。高さ区分0の平たい箱
	for b in 4:
		var sgn: Vector2 = Geo.BLOCKS[b]
		var lo := 2.0
		var c := sgn * (lo + (L - lo) * 0.5)
		_box(root, Vector3(L - lo, 0.04, L - lo), c, 0.0, _mat(AREA_COLORS[b]))
	# 道路
	var road := _mat(C_ROAD)
	_road_mat = road
	_box(root, Vector3(L * 2, 0.02, 2.0), Vector2.ZERO, 0.0, road)
	_box(root, Vector3(2.0, 0.02, L * 2), Vector2.ZERO, 0.0, road)
	# 歩道（各エリアのL字）
	var walk := _mat(C_WALK)
	for b in 4:
		var sgn: Vector2 = Geo.BLOCKS[b]
		_box(root, Vector3(L - 1.0, 0.05, 1.0), Vector2(sgn.x * (1.0 + (L - 1.0) * 0.5), sgn.y * 1.5), 0.0, walk)
		_box(root, Vector3(1.0, 0.05, L - 2.0), Vector2(sgn.x * 1.5, sgn.y * (2.0 + (L - 2.0) * 0.5)), 0.0, walk)
	# 中央線
	var line := _mat(C_LINE)
	for sgn in [-1.0, 1.0]:
		_box(root, Vector3(L - 1.0, 0.025, 0.06), Vector2(sgn * (1.0 + (L - 1.0) * 0.5), 0.0), 0.0, line)
		_box(root, Vector3(0.06, 0.025, L - 1.0), Vector2(0.0, sgn * (1.0 + (L - 1.0) * 0.5)), 0.0, line)

func _build_dynamic() -> void:
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.5
	cyl.bottom_radius = 0.5
	cyl.height = 0.05
	_event_mm = MultiMesh.new()
	_event_mm.transform_format = MultiMesh.TRANSFORM_3D
	_event_mm.use_colors = true
	_event_mm.mesh = cyl
	_event_mm.instance_count = MAX_EVENTS
	_event_mm.visible_instance_count = 0
	var emi := MultiMeshInstance3D.new()
	emi.multimesh = _event_mm
	var em := _mat(Color.WHITE, 0.6, true)
	em.vertex_color_use_as_albedo = true
	emi.material_override = em
	emi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(emi)

## 信号機（4本の柱と灯器）＋横断歩道＋停止線
func _build_signal() -> void:
	_signal_root = _make_signal_set(false)
	_signal_root.visible = false
	add_child(_signal_root)

func _make_signal_set(ghost: bool) -> Node3D:
	var root := Node3D.new()
	var white := _mat(C_WHITE, 0.5 if ghost else 1.0)
	var pole := _mat(Color(0.3, 0.3, 0.32), 0.5 if ghost else 1.0)
	for arm in 4:
		var a: Vector2 = Geo.ARMS[arm]
		# 横断歩道（中心から 2.0〜3.0）
		var cw_center := a * (1.5 + Tuning.CROSSWALK_T)
		var across := Geo.left_of(a)
		for k in range(-2, 3):
			var p := cw_center + across * (k * 0.4)
			var sz := Vector3(1.0, 0.02, 0.2) if absf(a.x) > 0.5 else Vector3(0.2, 0.02, 1.0)
			_box(root, sz, p, 0.03, white)
		# 停止線（交差点に向かう車線のみ）
		var sl := Geo.inbound_point(arm, Tuning.STOP_LINE_R)
		var slz := Vector3(0.08, 0.02, 1.0) if absf(a.x) > 0.5 else Vector3(1.0, 0.02, 0.08)
		_box(root, slz, sl, 0.03, white)
		# 柱と灯器（その方向から来る車から見て手前左の歩道）
		var pp := a * 3.3 + Geo.left_of(-a) * 1.55
		_box(root, Vector3(0.08, 1.1, 0.08), pp, 0.0, pole)
		var head := _box(root, Vector3(0.22, 0.22, 0.22), pp, 1.1, _mat(Color.GREEN, 0.5 if ghost else 1.0, true))
		var ped_head := _box(root, Vector3(0.14, 0.14, 0.14), pp, 0.7, _mat(Color.RED, 0.5 if ghost else 1.0, true))
		if not ghost:
			_car_lamps[arm] = head.material_override
			# 歩行者用の灯器は、その柱の脇の横断歩道（同じ道路）を示す
			_ped_lamps[arm] = ped_head.material_override
	return root

func _build_placement() -> void:
	_highlight_mat = _mat(Color(1.0, 0.85, 0.2), 0.35, true)
	_highlight = _box(self, Vector3(6.4, 0.06, 6.4), Vector2.ZERO, 0.05, _highlight_mat)
	_highlight.visible = false
	_ghost_root = _make_signal_set(true)
	_ghost_root.visible = false
	add_child(_ghost_root)

func set_highlight(on: bool) -> void:
	_highlight.visible = on

func set_ghost(on: bool) -> void:
	_ghost_root.visible = on

## 交差点（信号を置ける場所）に当たっているか
static func hits_intersection(p: Vector2) -> bool:
	return absf(p.x) < 3.4 and absf(p.y) < 3.4

# ---------------------------------------------------------------------
# 第1弾: 熱マップ・安心の波・選択リング・街灯
# ---------------------------------------------------------------------
const MAX_HEAT := 700

func _build_extras() -> void:
	# 熱マップ（停止中のみ表示）
	var quad := BoxMesh.new()
	quad.size = Vector3(0.96, 0.02, 0.96)
	_heat_mm = MultiMesh.new()
	_heat_mm.transform_format = MultiMesh.TRANSFORM_3D
	_heat_mm.use_colors = true
	_heat_mm.mesh = quad
	_heat_mm.instance_count = MAX_HEAT
	_heat_mm.visible_instance_count = 0
	_heat_node = MultiMeshInstance3D.new()
	_heat_node.multimesh = _heat_mm
	var hm := _mat(Color.WHITE, 0.6, true)
	hm.vertex_color_use_as_albedo = true
	_heat_node.material_override = hm
	_heat_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_heat_node.visible = false
	add_child(_heat_node)
	# 安心の波
	var tm := TorusMesh.new()
	tm.inner_radius = 0.9
	tm.outer_radius = 1.0
	tm.rings = 48
	tm.ring_segments = 6
	_wave_ring = MeshInstance3D.new()
	_wave_ring.mesh = tm
	_wave_mat = _mat(Color(0.75, 1.0, 0.8), 0.9, true)
	_wave_ring.material_override = _wave_mat
	_wave_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_wave_ring.visible = false
	add_child(_wave_ring)
	# 街灯（夜に灯る）
	_pool_mat = _mat(Color(1.0, 0.78, 0.4), 0.0, true)
	_pool_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var pool_mesh := CylinderMesh.new()
	pool_mesh.top_radius = 1.9
	pool_mesh.bottom_radius = 1.9
	pool_mesh.height = 0.01
	var pole := _mat(Color(0.28, 0.28, 0.3))
	for b in 4:
		var sg: Vector2 = Geo.BLOCKS[b]
		for p in [Vector2(1.95, 6.0), Vector2(6.0, 1.95)]:
			var pos := Vector2(sg.x * p.x, sg.y * p.y)
			_box(self, Vector3(0.07, 1.5, 0.07), pos, 0.0, pole)
			var lm := StandardMaterial3D.new()
			lm.albedo_color = Color(1.0, 0.92, 0.7)
			lm.emission_enabled = true
			lm.emission = Color(1.0, 0.85, 0.5)
			lm.emission_energy_multiplier = 0.1
			var head := MeshInstance3D.new()
			var sph := SphereMesh.new()
			sph.radius = 0.14
			sph.height = 0.28
			head.mesh = sph
			head.material_override = lm
			head.position = Vector3(pos.x, 1.55, pos.y)
			head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(head)
			_lamp_mats.append(lm)
			var pool := MeshInstance3D.new()
			pool.mesh = pool_mesh
			pool.material_override = _pool_mat
			pool.position = Vector3(pos.x, 0.09, pos.y)
			pool.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(pool)

## 雨の日は路面が濡れて暗くなる（見た目だけ）
func set_wet(on: bool) -> void:
	_road_mat.albedo_color = C_ROAD.darkened(0.35) if on else C_ROAD
	_road_mat.roughness = 0.35 if on else 1.0

func set_heat_visible(on: bool) -> void:
	_heat_node.visible = on

## 夜の明るさ（0=昼, 1=夜）。街灯の光り方を変える
func set_night(f: float) -> void:
	for m in _lamp_mats:
		m.emission_energy_multiplier = 0.1 + 3.0 * f
	_pool_mat.albedo_color.a = 0.16 * f

func _update_extras() -> void:
	if _heat_node.visible:
		var n := 0
		for key in sim.heat:
			var v: float = sim.heat[key]
			if v < 0.4 or n >= MAX_HEAT:
				continue
			var t := clampf(v / Tuning.HEAT_FULL, 0.0, 1.0)
			_heat_mm.set_instance_transform(n, Transform3D(Basis(), Vector3(key.x + 0.5, 0.08, key.y + 0.5)))
			_heat_mm.set_instance_color(n, Color(1.0, 0.85, 0.1, 0.30).lerp(Color(0.95, 0.1, 0.05, 0.80), t))
			n += 1
		_heat_mm.visible_instance_count = n
	if sim.waves.size() > 0:
		var r: float = sim.waves[0].r
		_wave_ring.visible = true
		_wave_ring.scale = Vector3(maxf(r, 0.1), 0.25, maxf(r, 0.1))
		_wave_ring.position = Vector3(0, 0.12, 0)
		_wave_mat.albedo_color.a = clampf(1.0 - r / Tuning.WAVE_MAX_R, 0.0, 0.9)
	else:
		_wave_ring.visible = false

# ---------------------------------------------------------------------
func _process(delta: float) -> void:
	if sim == null:
		return
	_t += delta
	if _highlight.visible:
		_highlight_mat.albedo_color.a = 0.25 + 0.2 * sin(_t * 5.0)
	_update_extras()
	_update_signal()
	_update_events()

func _update_signal() -> void:
	_signal_root.visible = sim.signal_on
	if not sim.signal_on:
		return
	for arm in 4:
		var st := sim.car_light(arm)
		var col := Color(0.1, 0.95, 0.3) if st == 0 else (Color(1.0, 0.8, 0.1) if st == 1 else Color(1.0, 0.15, 0.1))
		_car_lamps[arm].albedo_color = col
		var pg := sim.ped_green_left(arm) > 0.0
		_ped_lamps[arm].albedo_color = Color(0.1, 0.95, 0.3) if pg else Color(1.0, 0.15, 0.1)

func _update_events() -> void:
	var n := mini(sim.events.size(), MAX_EVENTS)
	_event_mm.visible_instance_count = n
	for i in n:
		var e = sim.events[i]
		var k: float = e.t / 1.5
		var s := 0.4 + k * 1.6
		var t := Transform3D(Basis().scaled(Vector3(s, 1.0, s)), Vector3(e.pos.x, 0.08, e.pos.y))
		_event_mm.set_instance_transform(i, t)
		_event_mm.set_instance_color(i, Color(1.0, 0.2, 0.1, 1.0 - k))
