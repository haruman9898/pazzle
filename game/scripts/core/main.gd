extends Node3D
## Placeholder entry scene. Replaced by the greybox prototype.

func _ready() -> void:
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 20.0
	cam.position = Vector3(10, 10, 10)
	add_child(cam)
	cam.look_at(Vector3.ZERO)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, 30, 0)
	add_child(light)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(16, 16)
	ground.mesh = plane
	add_child(ground)
	print("BOOT_OK")
