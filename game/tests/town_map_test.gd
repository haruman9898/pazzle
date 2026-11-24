extends SceneTree
## 地図・経路探索・歩道グラフの基本確認
func _init() -> void:
	# 経路: 住宅(id3, 縦道 x=-8 上 z=0.5) → オフィス(id2, 横道 z=-8 上 x=13.5)
	var r := TownMap.plan_route(2, 0.5, 0, 13.5)
	print("route home3->office: ", r)
	var r2 := TownMap.plan_route(0, -13.5, 0, 13.5)
	print("route home0->office (same line): ", r2)
	var r3 := TownMap.plan_route(1, -13.5, 3, 0.5)
	print("route home6->shop5: ", r3)
	var g := TownMap.build_walk_graph()
	print("walk cells: ", g.adj.size(), " edge cells: ", TownMap.edge_cells().size())
	# 全ペア到達確認
	var bad := 0
	for a in TownMap.BUILDINGS.size():
		for b in TownMap.BUILDINGS.size():
			if a == b: continue
			var ba: Dictionary = TownMap.BUILDINGS[a]
			var bb: Dictionary = TownMap.BUILDINGS[b]
			var rr := TownMap.plan_route(ba.line, ba.t, bb.line, bb.t)
			if rr.is_empty():
				bad += 1
	print("unreachable pairs: ", bad)
	quit()
