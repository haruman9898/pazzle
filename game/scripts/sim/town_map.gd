class_name TownMap
extends RefCounted
## ステージ1の地図（交差点4つ）。純ロジック（見た目に依存しない）。
## 座標は地面の (x, z) を Vector2(x, y) で表す。1マス = 1 = 現実の約3m。
## 道路の中心線は x=±8（縦道）と z=±8（横道）。左側通行。
##
## 方向（heading）: 0=東(+x) 1=西(-x) 2=北(-z) 3=南(+z)  … Geo.ARMS と同じ並び

const EXT := 18                  # 地図は -18〜18
const N := 36                    # セル数
const ROADS := [-8.0, 8.0]
const ROAD_HALF := 1.0
const LANE := 0.5
const WALK := 1.5
## 道路の線: 0=横道(z=-8) 1=横道(z=8) 2=縦道(x=-8) 3=縦道(x=8)
const LINE_COUNT := 4

## 建物: type / rect(x0,z0,幅,奥行) / height / door(歩道上の出入口) / line,t(車の出入口が接する道路と位置)
const BUILDINGS := [
	{"type": "home", "rect": Rect2(-17, -17, 6, 6), "height": 1.3, "door": Vector2(-13.5, -9.5), "line": 0, "t": -13.5},
	{"type": "shop", "rect": Rect2(-4, -16, 8, 5), "height": 1.0, "door": Vector2(0.5, -9.5), "line": 0, "t": 0.5},
	{"type": "office", "rect": Rect2(11, -17, 6, 6), "height": 3.2, "door": Vector2(13.5, -9.5), "line": 0, "t": 13.5},
	{"type": "home", "rect": Rect2(-17, -4, 6, 8), "height": 1.3, "door": Vector2(-9.5, 0.5), "line": 2, "t": 0.5},
	{"type": "school", "rect": Rect2(-5, -5, 10, 10), "height": 1.5, "door": Vector2(-6.5, 0.5), "line": 2, "t": 0.5},
	{"type": "shop", "rect": Rect2(11, -4, 6, 8), "height": 1.0, "door": Vector2(9.5, 0.5), "line": 3, "t": 0.5},
	{"type": "home", "rect": Rect2(-17, 11, 6, 6), "height": 1.3, "door": Vector2(-13.5, 9.5), "line": 1, "t": -13.5},
	{"type": "home", "rect": Rect2(-4, 11, 8, 6), "height": 1.3, "door": Vector2(0.5, 9.5), "line": 1, "t": 0.5},
	{"type": "home", "rect": Rect2(11, 11, 6, 6), "height": 1.3, "door": Vector2(13.5, 9.5), "line": 1, "t": 13.5},
]

# ---------------------------------------------------------------------
# 道路
# ---------------------------------------------------------------------
static func line_axis(l: int) -> int:
	return 0 if l < 2 else 1          # 0=横道（x方向に走る）1=縦道（z方向に走る）

static func line_c(l: int) -> float:
	return ROADS[l % 2]

## 交差点番号 j = a*2 + b（a=縦道の番号, b=横道の番号）
static func junction_center(j: int) -> Vector2:
	return Vector2(ROADS[j / 2], ROADS[j % 2])

static func junction_index(a: int, b: int) -> int:
	return a * 2 + b

## 道路 l 上の位置 t（横道なら x、縦道なら z）の点
static func line_point(l: int, t: float) -> Vector2:
	return Vector2(t, line_c(l)) if line_axis(l) == 0 else Vector2(line_c(l), t)

## 道路 l 上の位置が、その道路の座標 t のどこにあたるか
static func line_coord(l: int, p: Vector2) -> float:
	return p.x if line_axis(l) == 0 else p.y

## 向き hd と、道路の符号付き方向（+1/-1）の変換
static func hd_of(l: int, sign: int) -> int:
	if line_axis(l) == 0:
		return 0 if sign > 0 else 1
	return 3 if sign > 0 else 2

static func sign_of(hd: int) -> int:
	return 1 if (hd == 0 or hd == 3) else -1

static func line_of_hd(j: int, hd: int) -> int:
	# 交差点 j を向き hd に通り抜けるときの道路
	if hd < 2:
		return j % 2            # 横道（b）
	return 2 + j / 2            # 縦道（a）

static func opposite(hd: int) -> int:
	return hd ^ 1

static func left_hd(hd: int) -> int:
	var v := Geo.left_of(Geo.ARMS[hd])
	return Geo.arm_index(v)

static func right_hd(hd: int) -> int:
	var v := -Geo.left_of(Geo.ARMS[hd])
	return Geo.arm_index(v)

## 車線上の点（左側通行）: 道路 l の位置 t、向き hd
static func lane_point(l: int, t: float, hd: int) -> Vector2:
	return line_point(l, t) + Geo.left_of(Geo.ARMS[hd]) * LANE

## 道路 l を向き sign に進むとき、位置 t の次の節点: {coord, junction（境界なら -1）}
static func ahead(l: int, t: float, sign: int) -> Dictionary:
	var nodes := [-float(EXT), -8.0, 8.0, float(EXT)]
	if sign > 0:
		for c in nodes:
			if c > t + 0.001:
				return {"coord": c, "junction": _node_junction(l, c)}
	else:
		for k in range(nodes.size() - 1, -1, -1):
			if nodes[k] < t - 0.001:
				return {"coord": nodes[k], "junction": _node_junction(l, nodes[k])}
	return {"coord": t, "junction": -1}

static func _node_junction(l: int, c: float) -> int:
	if absf(c) > 9.0:
		return -1
	var k := 0 if c < 0.0 else 1
	if line_axis(l) == 0:
		return junction_index(k, l)          # 横道 l=b、c は x → a=k
	return junction_index(l - 2, k)          # 縦道 a=l-2、c は z → b=k

## 経路探索: 道路 sl の位置 st から、道路 dl の位置 dt まで（車）
## 戻り値 {events:[{j,hin,hout}], hd0, hd_end} 。到達できなければ空
static func plan_route(sl: int, st: float, dl: int, dt: float) -> Dictionary:
	var best_cost := INF
	var best := {}
	var cost := {}
	var prev := {}
	var open: Array = []        # [cost, key]
	# 出発
	for sign in [1, -1]:
		var hd := hd_of(sl, sign)
		var ah := ahead(sl, st, sign)
		if sl == dl and (dt - st) * sign >= 0.0 and (dt - st) * sign <= (ah.coord - st) * sign + 0.001:
			var c0 := absf(dt - st)
			if c0 < best_cost:
				best_cost = c0
				best = {"events": [], "hd0": hd, "hd_end": hd}
			continue
		if ah.junction >= 0:
			var key: int = ah.junction * 4 + hd
			var c1: float = absf(ah.coord - st)
			if c1 < cost.get(key, INF):
				cost[key] = c1
				prev[key] = {"from": -1, "hd0": hd}
				open.append([c1, key])
	# ダイクストラ（状態は16個）
	var done := {}
	while not open.is_empty():
		open.sort_custom(func(a, b): return a[0] < b[0])
		var cur: Array = open.pop_front()
		var key: int = cur[1]
		if done.has(key):
			continue
		done[key] = true
		var c: float = cur[0]
		if c >= best_cost:
			break
		var j := key / 4
		var hin := key % 4
		var jc := junction_center(j)
		for hout in [hin, left_hd(hin), right_hd(hin)]:
			var l2 := line_of_hd(j, hout)
			var p0 := line_coord(l2, jc)
			var sgn := sign_of(hout)
			var ah2 := ahead(l2, p0, sgn)
			if l2 == dl and (dt - p0) * sgn >= 0.0 and (dt - p0) * sgn <= (ah2.coord - p0) * sgn + 0.001:
				var cg := c + absf(dt - p0)
				if cg < best_cost:
					best_cost = cg
					best = {"last": key, "hout": hout}
				continue
			if ah2.junction >= 0:
				var k2: int = ah2.junction * 4 + hout
				var c2: float = c + absf(ah2.coord - p0)
				if c2 < cost.get(k2, INF):
					cost[k2] = c2
					prev[k2] = {"from": key, "hout": hout}
					open.append([c2, k2])
	if best.is_empty():
		return {}
	if best.has("events"):
		return best
	# 復元: 各状態の hout は、次の状態の hin（道路に沿って進むため）
	var events: Array = []
	var k: int = best.last
	var hout: int = best.hout
	while true:
		events.push_front({"j": k / 4, "hin": k % 4, "hout": hout})
		var pv: Dictionary = prev[k]
		if pv.from < 0:
			return {"events": events, "hd0": pv.hd0, "hd_end": best.hout}
		hout = k % 4
		k = pv.from
	return {}

# ---------------------------------------------------------------------
# 歩道のセル格子
# ---------------------------------------------------------------------
const K_NONE := 0
const K_SIDE := 1
const K_ROAD_H := 2      # 横道の車道セル（z方向にだけ渡れる）
const K_ROAD_V := 3      # 縦道の車道セル（x方向にだけ渡れる）
const K_JUNCTION := 4

static func cell_of(p: Vector2) -> Vector2i:
	return Vector2i(int(floor(p.x)) + EXT, int(floor(p.y)) + EXT)

static func cell_center(c: Vector2i) -> Vector2:
	return Vector2(c.x - EXT + 0.5, c.y - EXT + 0.5)

static func cell_index(c: Vector2i) -> int:
	return c.y * N + c.x

static func in_map(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < N and c.y < N

static func road_near(v: float) -> int:
	for b in 2:
		if absf(v - ROADS[b]) < ROAD_HALF - 0.001:
			return b
	return -1

static func kind_at(c: Vector2i) -> int:
	if not in_map(c):
		return K_NONE
	var p := cell_center(c)
	var hr := road_near(p.y)       # 横道（z が中心線付近）
	var vr := road_near(p.x)
	if hr >= 0 and vr >= 0:
		return K_JUNCTION
	if hr >= 0:
		return K_ROAD_H
	if vr >= 0:
		return K_ROAD_V
	for r in ROADS:
		if absf(absf(p.x - r) - WALK) < 0.01 or absf(absf(p.y - r) - WALK) < 0.01:
			return K_SIDE
	return K_NONE

## 歩行者の通れるセルの隣接関係（静的）。
## adj[idx] = [[隣のidx, 道路に入る辺か(0/1), 入る道路セルの idx], ...]
static func build_walk_graph() -> Dictionary:
	var adj := {}
	var radj := {}
	for z in N:
		for x in N:
			var c := Vector2i(x, z)
			var k := kind_at(c)
			if k == K_NONE or k == K_JUNCTION:
				continue
			var i := cell_index(c)
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n: Vector2i = c + d
				var kn := kind_at(n)
				if kn == K_NONE or kn == K_JUNCTION:
					continue
				var ni := cell_index(n)
				var ok := false
				var enter := 0
				if k == K_SIDE and kn == K_SIDE:
					ok = true
				elif k == K_SIDE and kn == K_ROAD_H:
					ok = (d.x == 0)          # 横道は z 方向にだけ入れる
					enter = 1
				elif k == K_SIDE and kn == K_ROAD_V:
					ok = (d.y == 0)
					enter = 1
				elif k == K_ROAD_H and kn == K_ROAD_H:
					ok = (d.x == 0)
				elif k == K_ROAD_V and kn == K_ROAD_V:
					ok = (d.y == 0)
				elif k == K_ROAD_H and kn == K_SIDE:
					ok = (d.x == 0)
				elif k == K_ROAD_V and kn == K_SIDE:
					ok = (d.y == 0)
				if not ok:
					continue
				if not adj.has(i):
					adj[i] = []
				adj[i].append([ni, enter, ni if enter == 1 else -1])
				if not radj.has(ni):
					radj[ni] = []
				radj[ni].append([i, enter, ni if enter == 1 else -1])
	return {"adj": adj, "radj": radj}

## 端の歩道セル（通過する歩行者の出入口）16か所
static func edge_cells() -> Array:
	var out: Array = []
	for z in N:
		for x in N:
			var c := Vector2i(x, z)
			if kind_at(c) == K_SIDE and (x == 0 or x == N - 1 or z == 0 or z == N - 1):
				out.append(c)
	return out

## 4つの交差点の、横断歩道の行（道路セルの idx → [交差点 j, 腕 arm]）。信号を置くと使える
static func junction_xrows(j: int) -> Dictionary:
	var out := {}
	var jc := junction_center(j)
	for arm in 4:
		var a: Vector2 = Geo.ARMS[arm]
		var row := jc + a * 2.5              # 横断歩道の中心（腕の上、中心から 2.5）
		var across := Geo.left_of(a)
		for k in [-0.5, 0.5]:
			var p: Vector2 = row + across * k
			out[cell_index(cell_of(p))] = [j, arm]
	return out

## 路上の信号（横断歩道）の行: 道路 l の位置 t
static func line_xrows(l: int, t: float) -> Array:
	var out: Array = []
	var row := line_point(l, t)
	var across := Vector2(0, 1) if line_axis(l) == 0 else Vector2(1, 0)
	for k in [-0.5, 0.5]:
		out.append(cell_index(cell_of(row + across * k)))
	return out
