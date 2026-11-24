class_name CameraRig
extends Node3D
## アイソメトリック視点のカメラ。360度自由回転（スナップなし）、ズーム、移動、定位置に戻る。
## 回転速度・慣性は TBD（試作の初期値: 慣性なし）。

const PITCH_DEG := -35.264       # 真のアイソメトリックの仰角
const DIST := 40.0
const HOME_YAW := 45.0
var home_size := 16.0
const MIN_SIZE := 6.0
var max_size := 30.0
const ROTATE_DEG_PER_PX := 0.35  # 回転速度（初期値・TBD）
var pan_limit := 12.0

var cam: Camera3D
var yaw := HOME_YAW
var _shift_tween: Tween

func _ready() -> void:
	cam = Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = home_size
	cam.near = 0.1
	cam.far = 200.0
	add_child(cam)
	cam.rotation_degrees = Vector3(PITCH_DEG, 0, 0)
	cam.position = Basis(Vector3.RIGHT, deg_to_rad(PITCH_DEG)) * Vector3(0, 0, DIST)
	_apply()

func _apply() -> void:
	rotation_degrees = Vector3(0, yaw, 0)

## 地図の大きさに合わせる（ステージ1は広いので、遠くから見る）
func configure(home: float, max_s: float, pan: float) -> void:
	home_size = home
	max_size = max_s
	pan_limit = pan
	if cam != null:
		cam.size = home

func rotate_by_pixels(dx: float) -> void:
	yaw = fposmod(yaw - dx * ROTATE_DEG_PER_PX, 360.0)
	_apply()

func _world_per_px() -> float:
	return cam.size / maxf(get_viewport().get_visible_rect().size.y, 1.0)

func pan_by_pixels(rel: Vector2) -> void:
	var wpp := _world_per_px()
	var right := global_transform.basis.x
	var fwd := -global_transform.basis.z
	right.y = 0
	fwd.y = 0
	right = right.normalized()
	fwd = fwd.normalized()
	var k := 1.0 / sin(deg_to_rad(-PITCH_DEG))
	position += -right * rel.x * wpp + fwd * rel.y * wpp * k
	position.x = clampf(position.x, -pan_limit, pan_limit)
	position.z = clampf(position.z, -pan_limit, pan_limit)

func zoom_by(factor: float) -> void:
	cam.size = clampf(cam.size * factor, MIN_SIZE, max_size)

func go_home() -> void:
	var tw := create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	# 回転は近い向きで戻す
	var target := HOME_YAW
	var diff := fposmod(target - yaw + 180.0, 360.0) - 180.0
	tw.tween_method(func(v): yaw = v; _apply(), yaw, yaw + diff, 0.35)
	tw.tween_property(self, "position", Vector3.ZERO, 0.35)
	tw.tween_property(cam, "size", home_size, 0.35)

## 設置パネルを開いたとき、画面を左にずらす（パネル幅 px）
func shift_for_panel(panel_px: float) -> void:
	if _shift_tween:
		_shift_tween.kill()
	var target := panel_px * 0.5 * _world_per_px()
	_shift_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_shift_tween.tween_property(cam, "h_offset", target, 0.25)

## 画面上の点 → 地面 (y=0) の点
func screen_to_ground(screen: Vector2) -> Variant:
	var o := cam.project_ray_origin(screen)
	var d := cam.project_ray_normal(screen)
	if absf(d.y) < 0.0001:
		return null
	var t := -o.y / d.y
	var p := o + d * t
	return Vector2(p.x, p.z)
