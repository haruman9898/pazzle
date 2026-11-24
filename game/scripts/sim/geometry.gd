class_name Geo
extends RefCounted
## 1交差点の地図の形（純ロジック。表示に依存しない）。
## 座標は地面の (x, z) を Vector2(x, y) で表す。交差点の中心が原点。
## 左側通行（日本）。

## 道路の方向（中心から外向き）: 0=東 1=西 2=北 3=南
const ARMS := [Vector2(1, 0), Vector2(-1, 0), Vector2(0, -1), Vector2(0, 1)]
## 四隅のエリア（発生・吸収エリア）の符号: 0=北東 1=北西 2=南西 3=南東
const BLOCKS := [Vector2(1, -1), Vector2(-1, -1), Vector2(-1, 1), Vector2(1, 1)]
const SAMPLE := 0.25

## 進行方向 h の左側
static func left_of(h: Vector2) -> Vector2:
	return Vector2(h.y, -h.x)

static func arm_index(dir: Vector2) -> int:
	for i in ARMS.size():
		if ARMS[i].is_equal_approx(dir):
			return i
	return -1

## 交差点に向かう車線上の点（中心から距離 r）
static func inbound_point(arm: int, r: float) -> Vector2:
	var a: Vector2 = ARMS[arm]
	return a * r + left_of(-a) * Tuning.LANE_OFFSET

## 交差点から出ていく車線上の点
static func outbound_point(arm: int, r: float) -> Vector2:
	var a: Vector2 = ARMS[arm]
	return a * r + left_of(a) * Tuning.LANE_OFFSET

## エリアが接している2本の道路（水平方向の道路, 垂直方向の道路）
static func block_arms(block: int) -> Array:
	var b: Vector2 = BLOCKS[block]
	return [arm_index(Vector2(b.x, 0)), arm_index(Vector2(0, b.y))]

## エリアの歩道の角の点
static func block_corner(block: int) -> Vector2:
	return BLOCKS[block] * Tuning.WALK_OFFSET

## エリアの歩道上の点（道路 arm 沿い、角からの距離 t）
static func walk_point(block: int, arm: int, t: float) -> Vector2:
	return block_corner(block) + ARMS[arm] * t

## 歩道上の位置から (arm, t) を求める
static func walk_locate(block: int, p: Vector2) -> Array:
	var arms := block_arms(block)
	var c := block_corner(block)
	var d := p - c
	var th: float = d.dot(ARMS[arms[0]])
	var tv: float = d.dot(ARMS[arms[1]])
	if absf(tv) < absf(th):
		return [arms[0], maxf(th, 0.0)]
	return [arms[1], maxf(tv, 0.0)]

## 同じエリアの歩道（L字）上の距離
static func walk_dist(arm1: int, t1: float, arm2: int, t2: float) -> float:
	if arm1 == arm2:
		return absf(t1 - t2)
	return t1 + t2

## 2つのエリアが共有する道路（隣り合っていなければ -1）
static func shared_arm(b1: int, b2: int) -> int:
	var a1 := block_arms(b1)
	var a2 := block_arms(b2)
	for a in a1:
		if a in a2:
			return a
	return -1

## 位置 p が属するエリア（x, z の符号）
static func block_of(p: Vector2) -> int:
	var s := Vector2(signf(p.x) if p.x != 0.0 else 1.0, signf(p.y) if p.y != 0.0 else 1.0)
	for i in BLOCKS.size():
		if BLOCKS[i].is_equal_approx(s):
			return i
	return 0

## 折れ線を等間隔（SAMPLE）に打ち直す
static func resample(poly: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	if poly.size() == 0:
		return out
	out.append(poly[0])
	var carry := 0.0
	for i in range(poly.size() - 1):
		var a := poly[i]
		var b := poly[i + 1]
		var seg := a.distance_to(b)
		if seg <= 0.00001:
			continue
		var d := SAMPLE - carry
		while d <= seg:
			out.append(a.lerp(b, d / seg))
			d += SAMPLE
		carry = seg - (d - SAMPLE)
	if out[out.size() - 1].distance_to(poly[poly.size() - 1]) > 0.01:
		out.append(poly[poly.size() - 1])
	return out

## 交差点内の曲線（2次ベジェ）
static func box_curve(arm_in: int, arm_out: int) -> PackedVector2Array:
	var e := inbound_point(arm_in, Tuning.ROAD_HALF)
	var x := outbound_point(arm_out, Tuning.ROAD_HALF)
	var pts := PackedVector2Array()
	var a_in: Vector2 = ARMS[arm_in]
	var a_out: Vector2 = ARMS[arm_out]
	if a_out.is_equal_approx(-a_in):
		pts.append(e)
		pts.append(x)
		return pts
	# 2本の車線の延長線の交点を制御点にする
	var h_in := -a_in
	var ctrl: Vector2
	if absf(h_in.x) > 0.5:
		ctrl = Vector2(x.x, e.y)
	else:
		ctrl = Vector2(e.x, x.y)
	var n := 12
	for i in range(n + 1):
		var t := float(i) / n
		var p := e * (1 - t) * (1 - t) + ctrl * 2 * (1 - t) * t + x * t * t
		pts.append(p)
	return pts

## 交差点の4区画のビットマスク（点が交差点内にあるとき）
static func quad_bit(p: Vector2) -> int:
	if absf(p.x) >= Tuning.ROAD_HALF or absf(p.y) >= Tuning.ROAD_HALF:
		return 0
	var q := (1 if p.x >= 0 else 0) + (2 if p.y >= 0 else 0)
	return 1 << q

## 点と線分の距離
static func seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 < 0.000001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)
