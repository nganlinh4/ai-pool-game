class_name CueStick
extends Node3D

var mesh_instance: MeshInstance3D
var offset_dist: float = 0.15 # Distance from ball center to cue tip

func _ready():
	_build_cue_mesh()

func _build_cue_mesh():
	# Procedurally build a tapered pool cue
	mesh_instance = MeshInstance3D.new()
	var cylinder = CylinderMesh.new()
	cylinder.top_radius = 0.006 # 12mm tip
	cylinder.bottom_radius = 0.015 # 30mm handle
	cylinder.height = 1.45 # Standard 58 inches-ish
	cylinder.radial_segments = 16
	
	mesh_instance.mesh = cylinder
	
	# Rotate so cylinder points along Z axis (lengthwise)
	mesh_instance.rotation.x = -PI / 2
	# Offset so the tip is at local 0,0,0
	mesh_instance.position.z = cylinder.height / 2.0
	
	# Material (Wood)
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.6, 0.4, 0.2)
	mat.roughness = 0.4
	mat.rim_enabled = true
	mesh_instance.material_override = mat
	
	# Add a "Tip" visual (Blue chalk)
	var tip_mesh = MeshInstance3D.new()
	var tip_cyl = CylinderMesh.new()
	tip_cyl.top_radius = 0.006
	tip_cyl.bottom_radius = 0.006
	tip_cyl.height = 0.01
	tip_mesh.mesh = tip_cyl
	tip_mesh.rotation.x = -PI / 2
	tip_mesh.position.z = 0.005 # Just slightly forward
	
	var tip_mat = StandardMaterial3D.new()
	tip_mat.albedo_color = Color(0.1, 0.2, 0.8) # Blue chalk
	tip_mesh.material_override = tip_mat
	
	add_child(mesh_instance)
	mesh_instance.add_child(tip_mesh)

func update_transform(ball_pos: Vector3, aim_dir: Vector3, vertical_angle: float, pull_back: float):
	# Position at ball
	global_position = ball_pos
	
	# Look at ball
	var look_target = ball_pos - aim_dir
	look_at(look_target, Vector3.UP)
	
	# Apply pitch (vertical aiming)
	rotation.x = vertical_angle
	
	# Pull back animation
	# We move the mesh locally along Z to simulate pulling back
	var pull_vector = Vector3(0, 0, offset_dist + pull_back)
	mesh_instance.position.z = pull_vector.z + (1.45/2.0) # Reset offset + pull
