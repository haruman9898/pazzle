class_name TownView
extends Node3D
## ステージ1（交差点4つ）の表示。TownWorld の状態を読んで、箱と色で描く（グレーボックス）。
## モデル規約: ピボット = footprint の底面中心（地面 y=0）。

const C_GROUND := Color(0.36, 0.42, 0.34)
const C_LAWN := Color(0.42, 0.52, 0.38)
const C_ROAD := Color(0.22, 0.22, 0.24)
const C_WALK := Color(0.66, 0.66, 0.63)
const C_LINE := Color(0.85, 0.75, 0.3)
const C_WHITE := Color(0.92, 0.92, 0.92)
const WALL := {"home": Color(0.93, 0.82, 0.68), "shop": Color(0.95, 0.6, 0.35), "office": Color(0.62, 0.7, 0.82), "school": Color(0.96, 0.86, 0.45)}
const ROOF := {"home": Color(0.72, 0.38, 0.32), "shop": Color(0.55, 0.3, 0.2), "office": Color(0.4, 0.45, 0.55), "school": Color(0.75, 0.55, 0.25)}

var sim: TownWorld
var _road_mat: StandardMaterial3D
var _road_nodes: Array = []
var _hl_mat: StandardMaterial3D
var _hl_nodes: Array = []
var _ghost_root: Node3D
var _ghost_key := ""
var _sig_nodes := {}          # 信号 id -> {root, car, ped}
var _link_nodes: Array = []
var _link_mat: StandardMaterial3D
var _heat_mm: MultiMesh
var _heat_node: MultiMeshInstance3D
var _event_mm: MultiMesh
var _wave_ring: MeshInstance3D
var _wave_mat: StandardMaterial3D
var _lamp_mats: Array = []
var _pool_mat: StandardMaterial3D
var _win_mm: MultiMesh
var _win_lit: PackedFloat32Array
var _win_night := -1.0
var _t := 0.0

const MAX_HEAT := 1200
const MAX_EVENTS := 32

func setup(s: TownWorld) -> void:
	sim = s
	_build_static()
	_build_buildings()
	_build_lamps()
	_build_overlays()

# ---------------------------------------------------------------------
func _mat(color: Color, alpha := 1.0, unshaded := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(color.r, color.g, color.b, alpha)
	if alpha < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if unshaded:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m

func _box(parent: Node3D, size: Vector3, center_xz: Vector2, y0: float, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = Vector3(center_xz.x, y0 + size.y * 0.5, center_xz.y)
	parent.add_child(mi)
	return mi

func _mm_node(mesh: Mesh, count: int, mat: Material) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = count
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.material_override = mat
	add_child(mi)
	return mm

func _build_static() -> void:
	var E := float(TownMap.EXT)
	var root := Node3D.new()
	root.name = "Static"
	add_child(root)
	_box(root, Vector3(E * 2 + 6, 0.1, E * 2 + 6), Vector2.ZERO, -0.1, _mat(C_GROUND))
	# 区画（芝生）
	var lawn := _mat(C_LAWN)
	var spans := [[-E, -10.0], [-6.0, 6.0], [10.0, E]]
	for bx in 3:
		for bz in 3:
			var x0: float = spans[bx][0]
			var x1: float = spans[bx][1]
			var z0: float = spans[bz][0]
			var z1: float = spans[bz][1]
			_box(root, Vector3(x1 - x0, 0.03, z1 - z0), Vector2((x0 + x1) * 0.5, (z0 + z1) * 0.5), 0.0, lawn)
	# 道路
	_road_mat = _mat(C_ROAD)
	for l in TownMap.LINE_COUNT:
		var c := TownMap.line_c(l)
		var size := Vector3(E * 2, 0.04, 2.0) if TownMap.line_axis(l) == 0 else Vector3(2.0, 0.045, E * 2)
		var pos := Vector2(0, c) if TownMap.line_axis(l) == 0 else Vector2(c, 0)
		_road_nodes.append(_box(root, size, pos, 0.0, _road_mat))
	# 歩道（セル）
	var walk_cells: Array = []
	for z in TownMap.N:
		for x in TownMap.N:
			if TownMap.kind_at(Vector2i(x, z)) == TownMap.K_SIDE:
				walk_cells.append(TownMap.cell_center(Vector2i(x, z)))
	var bm := BoxMesh.new()
	bm.size = Vector3(1.0, 0.06, 1.0)
	var wm := _mm_node(bm, walk_cells.size(), _vc_material())
	for i in walk_cells.size():
		var p: Vector2 = walk_cells[i]
		wm.set_instance_transform(i, Transform3D(Basis(), Vector3(p.x, 0.03, p.y)))
		wm.set_instance_color(i, C_WALK)
	# 中央線（交差点の手前まで）
	var line := _mat(C_LINE)
	for l in TownMap.LINE_COUNT:
		for seg in [[-E, -9.2], [-6.8, 6.8], [9.2, E]]:
			var a: float = seg[0]
			var b: float = seg[1]
			var mid := (a + b) * 0.5
			var len := b - a
			var p := TownMap.line_point(l, mid)
			var size := Vector3(len, 0.02, 0.06) if TownMap.line_axis(l) == 0 else Vector3(0.06, 0.02, len)
			_box(root, size, p, 0.05, line)

func _vc_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	return m

func _build_buildings() -> void:
	var root := Node3D.new()
	root.name = "Buildings"
	add_child(root)
	var win_pos: Array = []      # [Vector3 位置, Vector3 大きさ]
	for b in TownMap.BUILDINGS:
		var r: Rect2 = b.rect
		var h: float = b.height
		var c := r.position + r.size * 0.5
		var type: String = b.type
		_box(root, Vector3(r.size.x, h, r.size.y), c, 0.03, _mat(WALL[type]))
		_box(root, Vector3(r.size.x + 0.2, 0.12, r.size.y + 0.2), c, 0.03 + h, _mat(ROOF[type]))
		if type == "school":
			# 校庭の目印（出入口の前の広場）
			_box(root, Vector3(r.size.x + 1.0, 0.02, r.size.y + 1.0), c, 0.031, _mat(Color(0.8, 0.75, 0.6)))
			_box(root, Vector3(r.size.x, h, r.size.y), c, 0.05, _mat(WALL[type]))
		# 窓（4面）
		var floors := maxi(1, int(h / 0.9))
		for f in floors:
			var y := 0.03 + 0.55 + f * 0.9
			if y > 0.03 + h - 0.3:
				continue
			var nx := int(r.size.x / 1.4)
			for i in nx:
				var x := r.position.x + (i + 0.5) * r.size.x / nx
				win_pos.append([Vector3(x, y, r.position.y - 0.02), Vector3(0.5, 0.35, 0.06)])
				win_pos.append([Vector3(x, y, r.position.y + r.size.y + 0.02), Vector3(0.5, 0.35, 0.06)])
			var nz := int(r.size.y / 1.4)
			for i in nz:
				var z := r.position.y + (i + 0.5) * r.size.y / nz
				win_pos.append([Vector3(r.position.x - 0.02, y, z), Vector3(0.06, 0.35, 0.5)])
				win_pos.append([Vector3(r.position.x + r.size.x + 0.02, y, z), Vector3(0.06, 0.35, 0.5)])
	var bm := BoxMesh.new()
	bm.size = Vector3.ONE
	var um := StandardMaterial3D.new()
	um.vertex_color_use_as_albedo = true
	um.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_win_mm = _mm_node(bm, win_pos.size(), um)
	_win_lit.resize(win_pos.size())
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	for i in win_pos.size():
		_win_lit[i] = 1.0 if rng.randf() < 0.55 else 0.0
		var wp: Array = win_pos[i]
		_win_mm.set_instance_transform(i, Transform3D(Basis.from_scale(wp[1]), wp[0]))
	set_night(0.0)

func _build_lamps() -> void:
	_pool_mat = _mat(Color(1.0, 0.78, 0.4), 0.0, true)
	var pool_mesh := CylinderMesh.new()
	pool_mesh.top_radius = 1.9
	pool_mesh.bottom_radius = 1.9
	pool_mesh.height = 0.01
	var pole := _mat(Color(0.28, 0.28, 0.3))
	var spots: Array = []
	for l in TownMap.LINE_COUNT:
		var c := TownMap.line_c(l)
		for t in [-14.0, -3.5, 3.5, 14.0]:
			for side in [-1.0, 1.0]:
				var off: float = side * 2.0     # 歩道の外側の縁
				var p := TownMap.line_point(l, t) + (Vector2(0, off) if TownMap.line_axis(l) == 0 else Vector2(off, 0))
				spots.append(p)
	for pos in spots:
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
		var pl := MeshInstance3D.new()
		pl.mesh = pool_mesh
		pl.material_override = _pool_mat
		pl.position = Vector3(pos.x, 0.1, pos.y)
		pl.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(pl)

func _build_overlays() -> void:
	# 熱マップ
	var quad := BoxMesh.new()
	quad.size = Vector3(0.96, 0.02, 0.96)
	var hm := _mat(Color.WHITE, 0.6, true)
	hm.vertex_color_use_as_albedo = true
	_heat_mm = _mm_node(quad, MAX_HEAT, hm)
	_heat_mm.visible_instance_count = 0
	_heat_node = get_child(get_child_count() - 1)
	_heat_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_heat_node.visible = false
	# ヒヤリの輪
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.5
	cyl.bottom_radius = 0.5
	cyl.height = 0.05
	var em := _mat(Color.WHITE, 0.6, true)
	em.vertex_color_use_as_albedo = true
	_event_mm = _mm_node(cyl, MAX_EVENTS, em)
	_event_mm.visible_instance_count = 0
	get_child(get_child_count() - 1).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
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
	# 置ける道路のハイライト
	_hl_mat = _mat(Color(1.0, 0.9, 0.3), 0.45, true)
	var E := float(TownMap.EXT)
	for l in TownMap.LINE_COUNT:
		var c := TownMap.line_c(l)
		var size := Vector3(E * 2, 0.02, 2.0) if TownMap.line_axis(l) == 0 else Vector3(2.0, 0.02, E * 2)
		var pos := Vector2(0, c) if TownMap.line_axis(l) == 0 else Vector2(c, 0)
		var n := _box(self, size, pos, 0.08, _hl_mat)
		n.visible = false
		n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_hl_nodes.append(n)
	# 連動の線
	_link_mat = _mat(Color(0.4, 0.9, 1.0), 0.85, true)
	_ghost_root = Node3D.new()
	_ghost_root.visible = false
	add_child(_ghost_root)

# ---------------------------------------------------------------------
# 外から呼ぶ
# ---------------------------------------------------------------------
func set_highlight(on: bool) -> void:
	for n in _hl_nodes:
		n.visible = on

func set_heat_visible(on: bool) -> void:
	_heat_node.visible = on

func set_wet(on: bool) -> void:
	_road_mat.albedo_color = C_ROAD.darkened(0.35) if on else C_ROAD
	_road_mat.roughness = 0.35 if on else 1.0

func set_night(f: float) -> void:
	for m in _lamp_mats:
		m.emission_energy_multiplier = 0.1 + 3.0 * f
	_pool_mat.albedo_color.a = 0.16 * f
	if absf(f - _win_night) < 0.02 or _win_mm == null:
		return
	_win_night = f
	var dim := Color(0.45, 0.55, 0.65)
	var lit := Color(1.0, 0.86, 0.5)
	for i in _win_mm.instance_count:
		_win_mm.set_instance_color(i, dim.lerp(lit, f * _win_lit[i]))

## 仮配置の見た目。pl は TownWorld.placement_at の結果
func set_ghost(on: bool, pl: Dictionary = {}) -> void:
	if not on or pl.is_empty() or not pl.get("ok", false):
		_ghost_root.visible = false
		_ghost_key = ""
		return
	var key := "%d:%s:%s" % [pl.kind, str(pl.get("j", -1)), str(pl.get("t", 0.0)) + "_" + str(pl.get("line", -1))]
	if key != _ghost_key:
		for c in _ghost_root.get_children():
			c.queue_free()
		var sg := {"kind": pl.kind, "j": pl.get("j", -1), "line": pl.get("line", -1), "t": pl.get("t", 0.0), "pos": pl.pos}
		_make_signal_visual(sg, true, _ghost_root)
		_ghost_key = key
	_ghost_root.visible = true

# ---------------------------------------------------------------------
# 信号の見た目
# ---------------------------------------------------------------------
func _make_signal_visual(sg: Dictionary, ghost: bool, parent: Node3D) -> Dictionary:
	var root := Node3D.new()
	parent.add_child(root)
	var a := 0.5 if ghost else 1.0
	var white := _mat(C_WHITE, a)
	var polem := _mat(Color(0.3, 0.3, 0.32), a)
	var car_lamps: Array = []
	var ped_lamps: Array = []
	if sg.kind == 0:
		var c := TownMap.junction_center(sg.j)
		for arm in 4:
			var av: Vector2 = Geo.ARMS[arm]
			var cw := c + av * 2.5
			var across := Geo.left_of(av)
			for k in range(-2, 3):
				var p := cw + across * (k * 0.4)
				var sz := Vector3(1.0, 0.02, 0.2) if absf(av.x) > 0.5 else Vector3(0.2, 0.02, 1.0)
				_box(root, sz, p, 0.09, white)
			var sl := c + Geo.inbound_point(arm, Tuning.STOP_LINE_R)
			var slz := Vector3(0.08, 0.02, 1.0) if absf(av.x) > 0.5 else Vector3(1.0, 0.02, 0.08)
			_box(root, slz, sl, 0.09, white)
			var pp := c + av * 3.3 + Geo.left_of(-av) * 1.55
			_box(root, Vector3(0.08, 1.1, 0.08), pp, 0.0, polem)
			var head := _box(root, Vector3(0.22, 0.22, 0.22), pp, 1.1, _mat(Color.GREEN, a, true))
			var ped := _box(root, Vector3(0.14, 0.14, 0.14), pp, 0.7, _mat(Color.RED, a, true))
			car_lamps.append([head.material_override, arm])
			ped_lamps.append([ped.material_override, arm])
	else:
		var l: int = sg.line
		var t: float = sg.t
		var p0 := TownMap.line_point(l, t)
		var across := Vector2(0, 1) if TownMap.line_axis(l) == 0 else Vector2(1, 0)
		for k in range(-2, 3):
			var p := p0 + across * (k * 0.4)
			var sz := Vector3(1.0, 0.02, 0.2) if TownMap.line_axis(l) == 0 else Vector3(0.2, 0.02, 1.0)
			_box(root, sz, p, 0.09, white)
		for sign in [1, -1]:
			var hd := TownMap.hd_of(l, sign)
			var sp := TownMap.lane_point(l, t - sign * 0.75, hd)
			var slz := Vector3(0.08, 0.02, 1.0) if TownMap.line_axis(l) == 0 else Vector3(1.0, 0.02, 0.08)
			_box(root, slz, sp, 0.09, white)
		for side in [-1.0, 1.0]:
			var pp: Vector2 = p0 + across * (side * 1.55)
			_box(root, Vector3(0.08, 1.1, 0.08), pp, 0.0, polem)
			var head := _box(root, Vector3(0.22, 0.22, 0.22), pp, 1.1, _mat(Color.GREEN, a, true))
			var ped := _box(root, Vector3(0.14, 0.14, 0.14), pp, 0.7, _mat(Color.RED, a, true))
			car_lamps.append([head.material_override, -1])
			ped_lamps.append([ped.material_override, -1])
	return {"root": root, "car": car_lamps, "ped": ped_lamps}

func _sync_signals() -> void:
	for id in _sig_nodes.keys():
		if not sim.signals.has(id):
			_sig_nodes[id].root.queue_free()
			_sig_nodes.erase(id)
	for id in sim.signals:
		if not _sig_nodes.has(id):
			_sig_nodes[id] = _make_signal_visual(sim.signals[id], false, self)
		var sg: Dictionary = sim.signals[id]
		var node: Dictionary = _sig_nodes[id]
		for e in node.car:
			var st := sim.car_light_of(sg, e[1])
			(e[0] as StandardMaterial3D).albedo_color = Color(0.1, 0.95, 0.3) if st == 0 else (Color(1.0, 0.8, 0.1) if st == 1 else Color(1.0, 0.15, 0.1))
		for e in node.ped:
			var g := sim.ped_left_of(sg, e[1]) > 0.0
			(e[0] as StandardMaterial3D).albedo_color = Color(0.1, 0.95, 0.3) if g else Color(1.0, 0.15, 0.1)
	# 連動の線
	var n := sim.links.size()
	while _link_nodes.size() < n:
		var bm := BoxMesh.new()
		bm.size = Vector3.ONE
		var mi := MeshInstance3D.new()
		mi.mesh = bm
		mi.material_override = _link_mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		_link_nodes.append(mi)
	for i in _link_nodes.size():
		var mi: MeshInstance3D = _link_nodes[i]
		if i >= n:
			mi.visible = false
			continue
		var lk: Dictionary = sim.links[i]
		var pa: Vector2 = sim.signals[lk.a].pos
		var pb: Vector2 = sim.signals[lk.b].pos
		var d := pb - pa
		var len := d.length()
		mi.visible = true
		var ang := atan2(-d.y, d.x)
		mi.transform = Transform3D(Basis(Vector3.UP, ang) * Basis.from_scale(Vector3(len, 0.05, 0.12)),
			Vector3((pa.x + pb.x) * 0.5, 0.55, (pa.y + pb.y) * 0.5))
	_link_mat.albedo_color.a = 0.55 + 0.3 * sin(_t * 4.0)

# ---------------------------------------------------------------------
func _process(delta: float) -> void:
	if sim == null:
		return
	_t += delta
	if _hl_nodes[0].visible:
		_hl_mat.albedo_color.a = 0.35 + 0.2 * sin(_t * 5.0)
	_sync_signals()
	_update_overlays()

func _update_overlays() -> void:
	if _heat_node.visible:
		var n := 0
		for key in sim.heat:
			var v: float = sim.heat[key]
			if v < 0.4 or n >= MAX_HEAT:
				continue
			var t := clampf(v / Tuning.HEAT_FULL, 0.0, 1.0)
			_heat_mm.set_instance_transform(n, Transform3D(Basis(), Vector3(key.x + 0.5, 0.1, key.y + 0.5)))
			_heat_mm.set_instance_color(n, Color(1.0, 0.85, 0.1, 0.30).lerp(Color(0.95, 0.1, 0.05, 0.80), t))
			n += 1
		_heat_mm.visible_instance_count = n
	if sim.waves.size() > 0:
		var w: Dictionary = sim.waves[0]
		_wave_ring.visible = true
		_wave_ring.scale = Vector3(maxf(w.r, 0.1), 0.25, maxf(w.r, 0.1))
		_wave_ring.position = Vector3(w.c.x, 0.14, w.c.y)
		_wave_mat.albedo_color.a = clampf(1.0 - w.r / Tuning.WAVE_MAX_R, 0.0, 0.9)
	else:
		_wave_ring.visible = false
	var ne := mini(sim.events.size(), MAX_EVENTS)
	_event_mm.visible_instance_count = ne
	for i in ne:
		var e = sim.events[i]
		var k: float = e.t / 1.5
		var s: float = 0.4 + k * 1.6
		_event_mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3(s, 1.0, s)), Vector3(e.pos.x, 0.1, e.pos.y)))
		_event_mm.set_instance_color(i, Color(1.0, 0.2, 0.1, 1.0 - k))
