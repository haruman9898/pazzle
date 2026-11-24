class_name AgentsView
extends Node3D
## 車・歩行者・街の人々（立ち話）・雨の描画。sim の状態を読むだけで、ロジックには触れない。
## すべて箱と色（グレーボックス）。見た目だけで違いが分かるようにし、文字は使わない。
##
## 見た目の約束:
##   役割は大きさと持ち物で見分ける（児童=小さく黄色い帽子とランドセル、通勤者=背が高くカバン、買い物客=買い物袋）
##   不満が高い人は赤くなる。安心の波が通った人は一瞬白く光る
##   横断中は手を挙げる（児童は必ず、大人は一部）。雨の日は傘をさす（見た目だけ。交通には影響しない）
##   街の人々は、立ち話をしている（シミュレーションには入らない飾り）

const MAX_CARS := 256
const MAX_PEOPLE := 760
const MAX_RAIN := 900

const C_ANGRY := Color(0.95, 0.2, 0.15)
const CAR_COLORS := [Color(0.45, 0.68, 0.95), Color(0.93, 0.93, 0.95), Color(0.72, 0.74, 0.8), Color(0.95, 0.8, 0.3), Color(0.45, 0.72, 0.55)]
const ROLE_COLORS := [Color(0.97, 0.96, 0.85), Color(0.78, 0.83, 0.93), Color(0.97, 0.88, 0.9)]   # 児童・通勤者・買い物客
const SKIN := [Color(0.96, 0.8, 0.66), Color(0.85, 0.65, 0.5), Color(0.7, 0.5, 0.38), Color(0.55, 0.38, 0.28)]
const UMBRELLAS := [Color(0.9, 0.25, 0.25), Color(0.25, 0.45, 0.9), Color(0.95, 0.8, 0.2), Color(0.3, 0.7, 0.4), Color(0.6, 0.35, 0.8), Color(0.2, 0.2, 0.25), Color(0.95, 0.55, 0.7)]
const PACKS := [Color(0.9, 0.25, 0.2), Color(0.2, 0.4, 0.9), Color(0.95, 0.6, 0.15)]
const BAGS := [Color(0.3, 0.7, 0.4), Color(0.9, 0.85, 0.7), Color(0.95, 0.5, 0.6)]
const CASES := [Color(0.25, 0.18, 0.12), Color(0.12, 0.12, 0.14)]

## 立ち話をしている2人組の場所と、いる時間帯 [x, z, 向き(0=南北に並ぶ, 1=東西に並ぶ), 開始時刻, 終了時刻]
const CHAT_SPOTS := [
	[2.7, -6.8, 0, 6.0, 21.0], [-6.8, 2.7, 1, 6.5, 20.5], [-2.7, 6.8, 0, 9.5, 17.0], [6.8, -2.7, 1, 9.0, 17.5],
	[2.7, 6.8, 0, 10.0, 16.5], [-6.8, -2.7, 1, 9.5, 17.0], [-2.7, -6.8, 0, 17.0, 21.0], [6.8, 2.7, 1, 17.5, 20.5],
]

var sim                      # SimWorld または TownWorld
var raining := false
var night := 0.0
var hour := 6.0

var chat_spots: Array = CHAT_SPOTS
var rain_extent := 14.0
var update_ms := 0.0              # 1フレームあたりの描画更新（GDScript）の時間（平滑化）
var _t := 0.0
var _car_body: MultiMesh
var _car_cabin: MultiMesh
var _car_lamps: MultiMesh
var _p_body: MultiMesh
var _p_head: MultiMesh
var _p_acc: MultiMesh
var _p_hat: MultiMesh
var _p_arm: MultiMesh
var _p_umb: MultiMesh
var _rain_mm: MultiMesh
var _rain_node: MultiMeshInstance3D
var _rain_pos := PackedVector3Array()
var _bi := 0
var _hi := 0
var _ai := 0
var _ci := 0
var _ari := 0
var _ui := 0

func setup(s) -> void:
	sim = s
	var lit := StandardMaterial3D.new()
	lit.vertex_color_use_as_albedo = true
	lit.emission_enabled = true
	lit.emission = Color(1, 1, 1)
	lit.emission_energy_multiplier = 0.18   # 夜でも見えるように、わずかに自発光させる
	var unlit := StandardMaterial3D.new()
	unlit.vertex_color_use_as_albedo = true
	unlit.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	var sph := SphereMesh.new()
	sph.radius = 0.5
	sph.height = 1.0
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.5
	cone.height = 1.0
	cone.radial_segments = 10
	cone.rings = 1
	_car_body = _mk(box, MAX_CARS, lit)
	_car_cabin = _mk(box, MAX_CARS, lit)
	_car_lamps = _mk(box, MAX_CARS * 4, unlit)
	_p_body = _mk(box, MAX_PEOPLE, lit)
	_p_head = _mk(sph, MAX_PEOPLE, lit)
	_p_acc = _mk(box, MAX_PEOPLE, lit)
	_p_hat = _mk(box, MAX_PEOPLE, lit)
	_p_arm = _mk(box, MAX_PEOPLE, lit)
	_p_umb = _mk(cone, MAX_PEOPLE, lit)
	# 雨
	var rain_mat := StandardMaterial3D.new()
	rain_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rain_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rain_mat.albedo_color = Color(0.75, 0.85, 1.0, 0.5)
	_rain_mm = MultiMesh.new()
	_rain_mm.transform_format = MultiMesh.TRANSFORM_3D
	_rain_mm.mesh = box
	_rain_mm.instance_count = MAX_RAIN
	_rain_node = MultiMeshInstance3D.new()
	_rain_node.multimesh = _rain_mm
	_rain_node.material_override = rain_mat
	_rain_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rain_node.visible = false
	add_child(_rain_node)
	_scatter_rain()

## 雨粒を、見える範囲に散らす（地図が広いときは範囲を広げる）
func configure(extent: float, spots: Array) -> void:
	rain_extent = extent
	chat_spots = spots
	_scatter_rain()

func _scatter_rain() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	_rain_pos.clear()
	for i in MAX_RAIN:
		_rain_pos.append(Vector3(rng.randf_range(-rain_extent, rain_extent), rng.randf_range(0, 10), rng.randf_range(-rain_extent, rain_extent)))

func _mk(mesh: Mesh, count: int, mat: Material) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = count
	mm.visible_instance_count = 0
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.material_override = mat
	add_child(mi)
	return mm

func set_raining(on: bool) -> void:
	raining = on
	_rain_node.visible = on

## 部品を1つ置く。base=足元, rot=向き, lp=向きに対する位置, s=全体の拡大（安心の波の演出）
func _put(mm: MultiMesh, idx: int, base: Vector3, rot: Basis, lp: Vector3, size: Vector3, color: Color, s: float, extra: Basis = Basis.IDENTITY) -> void:
	var b := rot * extra * Basis.from_scale(size * s)
	mm.set_instance_transform(idx, Transform3D(b, base + rot * (lp * s)))
	mm.set_instance_color(idx, color)

func _process(delta: float) -> void:
	if sim == null:
		return
	_t += delta
	var t0 := Time.get_ticks_usec()
	_update_cars()
	_update_people()
	if raining:
		_update_rain(delta)
	update_ms = lerpf(update_ms, (Time.get_ticks_usec() - t0) / 1000.0, 0.1)

# ---------------------------------------------------------------------
# 車: 型（セダン／ハッチバック／バン）と色が違う。夜は前が白く、後ろが赤く光る
# ---------------------------------------------------------------------
func _update_cars() -> void:
	var n := mini(sim.cars.size(), MAX_CARS)
	var li := 0
	var front_col: Color = Color(0.75, 0.72, 0.6).lerp(Color(1.0, 0.97, 0.75), night)
	var rear_col: Color = Color(0.5, 0.1, 0.1).lerp(Color(1.0, 0.1, 0.08), night)
	for i in n:
		var c = sim.cars[i]
		var kind: int = c.look % 3
		var mood: float = clampf(c.d / 100.0, 0.0, 1.0)
		var col: Color = (CAR_COLORS[(c.look / 3) % CAR_COLORS.size()] as Color).lerp(C_ANGRY, mood).lerp(Color.WHITE, c.pulse * 0.6)
		var rot := Basis(Vector3.UP, atan2(-c.dir.y, c.dir.x))
		var s: float = 1.0 + 0.5 * c.pulse
		var base := Vector3(c.pos.x, 0.0, c.pos.y)
		var length := 0.8
		var width := 0.42
		var h := 0.22
		var cab := Vector3(0.42, 0.2, 0.36)
		var cab_x := -0.06
		if kind == 1:
			length = 0.68
			cab = Vector3(0.4, 0.22, 0.36)
			cab_x = -0.02
		elif kind == 2:
			h = 0.3
			cab = Vector3(0.6, 0.26, 0.4)
			cab_x = -0.08
		_put(_car_body, i, base, rot, Vector3(0, 0.03 + h * 0.5, 0), Vector3(length, h, width), col, s)
		_put(_car_cabin, i, base, rot, Vector3(cab_x, 0.03 + h + cab.y * 0.5, 0), cab, col.darkened(0.22), s)
		for side in [-1.0, 1.0]:
			_put(_car_lamps, li, base, rot, Vector3(length * 0.5 - 0.01, 0.03 + h * 0.5, side * width * 0.32), Vector3(0.05, 0.07, 0.1), front_col, s)
			li += 1
			_put(_car_lamps, li, base, rot, Vector3(-length * 0.5 + 0.01, 0.03 + h * 0.5, side * width * 0.32), Vector3(0.05, 0.07, 0.1), rear_col, s)
			li += 1
	_car_body.visible_instance_count = n
	_car_cabin.visible_instance_count = n
	_car_lamps.visible_instance_count = li

# ---------------------------------------------------------------------
# 人: 役割・持ち物・歩きの揺れ・手を挙げる・傘。街の人々は立ち話
# ---------------------------------------------------------------------
func _update_people() -> void:
	_bi = 0
	_hi = 0
	_ai = 0
	_ci = 0
	_ari = 0
	_ui = 0
	for p in sim.peds:
		if _bi >= MAX_PEOPLE - 20:
			break
		var bob := 0.0
		if not p.waiting:
			bob = 0.025 * absf(sin(_t * 9.0 + float(p.id)))
		_person(p.pos, p.dir, p.role, p.look, clampf(p.d / 100.0, 0.0, 1.0), p.pulse, bob, p.crossing, float(p.id), 1.0)
	_update_chatters()
	_p_body.visible_instance_count = _bi
	_p_head.visible_instance_count = _hi
	_p_acc.visible_instance_count = _ai
	_p_hat.visible_instance_count = _ci
	_p_arm.visible_instance_count = _ari
	_p_umb.visible_instance_count = _ui

func _person(pos2: Vector2, dir: Vector2, role: int, look: int, mood: float, pulse: float, bob: float, crossing: bool, phase: float, fade: float) -> void:
	var s: float = (1.0 + 0.6 * pulse) * fade
	var rot := Basis(Vector3.UP, atan2(-dir.y, dir.x))
	var base := Vector3(pos2.x, bob, pos2.y)
	var col: Color = (ROLE_COLORS[role] as Color).lerp(C_ANGRY, mood).lerp(Color.WHITE, pulse * 0.6)
	var bsz := Vector3(0.24, 0.5, 0.24)
	var hd := 0.2
	if role == SimWorld.ROLE_CHILD:
		bsz = Vector3(0.2, 0.34, 0.2)
		hd = 0.19
	elif role == SimWorld.ROLE_SHOPPER:
		bsz = Vector3(0.27, 0.46, 0.27)
	var skin: Color = SKIN[look % SKIN.size()]
	_put(_p_body, _bi, base, rot, Vector3(0, bsz.y * 0.5, 0), bsz, col, s)
	_bi += 1
	var head_y := bsz.y + hd * 0.5 - 0.02
	_put(_p_head, _hi, base, rot, Vector3(0, head_y, 0), Vector3(hd, hd, hd), skin, s)
	_hi += 1
	var top := head_y + hd * 0.5
	var v := look >> 4
	if role == SimWorld.ROLE_CHILD:
		_put(_p_hat, _ci, base, rot, Vector3(0, top - 0.01, 0), Vector3(hd * 1.12, 0.05, hd * 1.12), Color(1.0, 0.85, 0.15), s)
		_ci += 1
		_put(_p_acc, _ai, base, rot, Vector3(-0.13, bsz.y * 0.62, 0), Vector3(0.08, 0.2, 0.16), PACKS[v % PACKS.size()], s)
		_ai += 1
	elif role == SimWorld.ROLE_COMMUTER:
		_put(_p_acc, _ai, base, rot, Vector3(0.0, 0.2, 0.17), Vector3(0.2, 0.14, 0.05), CASES[v % CASES.size()], s)
		_ai += 1
	else:
		_put(_p_acc, _ai, base, rot, Vector3(0.0, 0.14, 0.18), Vector3(0.14, 0.2, 0.1), BAGS[v % BAGS.size()], s)
		_ai += 1
	# 横断中は手を挙げる（児童は必ず、大人は一部）
	if crossing and (role == SimWorld.ROLE_CHILD or look % 3 == 0):
		var swing := sin(_t * 7.0 + phase) * 0.22
		_put(_p_arm, _ari, base, rot, Vector3(0, bsz.y + 0.1, -0.15), Vector3(0.06, 0.3, 0.06), skin, s, Basis(Vector3.RIGHT, swing))
		_ari += 1
	# 雨の日は傘をさす（見た目だけ）
	if raining:
		var ucol: Color = Color(1.0, 0.85, 0.15) if role == SimWorld.ROLE_CHILD else UMBRELLAS[v % UMBRELLAS.size()]
		_put(_p_umb, _ui, base, rot, Vector3(0, top + 0.1, 0), Vector3(0.8, 0.16, 0.8), ucol, s)
		_ui += 1

func _fade(h: float, t0: float, t1: float) -> float:
	return clampf((h - t0) / 0.4, 0.0, 1.0) * clampf((t1 - h) / 0.4, 0.0, 1.0)

func _update_chatters() -> void:
	for i in chat_spots.size():
		var sp: Array = chat_spots[i]
		var f := _fade(hour, sp[3], sp[4])
		if f < 0.05 or _bi >= MAX_PEOPLE - 4:
			continue
		var c := Vector2(sp[0], sp[1])
		var off := Vector2(0.0, 0.22) if sp[2] == 0 else Vector2(0.22, 0.0)
		var pa := c + off
		var pb := c - off
		var ph := float(i) * 1.7
		var sway := sin(_t * 1.3 + ph) * 0.25
		var da := (pb - pa).normalized().rotated(sway)
		var db := (pa - pb).normalized().rotated(-sway)
		var look_a: int = (i * 2654435761) & 0x7fffffff
		var look_b: int = (i * 40503 + 977) & 0x7fffffff
		var role_a: int = [SimWorld.ROLE_COMMUTER, SimWorld.ROLE_SHOPPER, SimWorld.ROLE_SHOPPER, SimWorld.ROLE_COMMUTER][i % 4]
		var role_b: int = [SimWorld.ROLE_SHOPPER, SimWorld.ROLE_SHOPPER, SimWorld.ROLE_COMMUTER, SimWorld.ROLE_COMMUTER][(i + 1) % 4]
		# 話すたびに少し頷く
		_person(pa, da, role_a, look_a, 0.0, 0.0, 0.012 * (0.5 + 0.5 * sin(_t * 4.0 + ph)), false, ph, f)
		_person(pb, db, role_b, look_b, 0.0, 0.0, 0.012 * (0.5 + 0.5 * sin(_t * 4.0 + ph + 2.0)), false, ph + 1.0, f)

# ---------------------------------------------------------------------
func _update_rain(delta: float) -> void:
	var tilt := Basis(Vector3(0, 0, 1), 0.12) * Basis.from_scale(Vector3(0.012, 0.5, 0.012))
	for i in MAX_RAIN:
		var p := _rain_pos[i]
		p.y -= 16.0 * delta
		if p.y < 0.0:
			p.y += 10.0
		_rain_pos[i] = p
		_rain_mm.set_instance_transform(i, Transform3D(tilt, p))
