class_name PoolBall3D
extends RigidBody3D

enum BallType { CUE, SOLID, STRIPE, EIGHT }

@export var ball_number: int = 0
@export var ball_type: BallType = BallType.SOLID

# Visuals
var _mesh_instance: MeshInstance3D
var _ball_color: Color = Color.WHITE

# Audio
var audio_player: AudioStreamPlayer3D
var hit_sound: AudioStream
var rail_sound: AudioStream

# State
var is_stopped: bool = true
const STOP_THRESHOLD: float = 0.02
const ROLLING_DAMP: float = 1.5  # Increased: Cloth friction is high
const DRAG_DAMP: float = 0.8     # Air resistance

# Sound/Rules
signal collided(intensity, pos)
var first_collision_body: Node = null
var last_collision_time: float = 0.0

func _ready():
	continuous_cd = true 
	contact_monitor = true
	max_contacts_reported = 3
	mass = 1.0 
	
	if physics_material_override == null:
		var mat = PhysicsMaterial.new()
		mat.bounce = 0.75 # Slightly less bounce for "heavy" feel
		mat.friction = 0.5 
		physics_material_override = mat

	linear_damp = DRAG_DAMP
	angular_damp = ROLLING_DAMP
	
	_setup_visuals()
	_setup_audio()

func setup(number: int, type: int, color: Color):
	ball_number = number
	ball_type = type
	_ball_color = color
	# Refresh material if called after ready
	if _mesh_instance: _create_procedural_material(_ball_color)

func launch(impulse: Vector3):
	is_stopped = false
	sleeping = false
	first_collision_body = null
	apply_central_impulse(impulse)

func _integrate_forces(state):
	# Aggressive stopping to prevent "creeping" balls
	var v_len = state.linear_velocity.length()
	var a_len = state.angular_velocity.length()
	
	if v_len < STOP_THRESHOLD and a_len < STOP_THRESHOLD:
		if not is_stopped:
			state.linear_velocity = Vector3.ZERO
			state.angular_velocity = Vector3.ZERO
			is_stopped = true
			sleeping = true
	else:
		is_stopped = false
		
	# Collision Audio Logic
	if state.get_contact_count() > 0:
		var current_vel = state.linear_velocity
		var impact_force = current_vel.length()
		
		# Record first collision for Rule Engine
		if first_collision_body == null:
			var col = state.get_contact_collider_object(0)
			if col is PoolBall3D or col is StaticBody3D:
				first_collision_body = col

		if impact_force > 0.2 and (Time.get_ticks_msec() - last_collision_time) > 80:
			var collider = state.get_contact_collider_object(0)
			
			if audio_player and (hit_sound or rail_sound):
				if collider is PoolBall3D and hit_sound:
					audio_player.stream = hit_sound
					# Pitch up slightly for balls
					audio_player.pitch_scale = randf_range(0.9, 1.1)
				elif rail_sound:
					audio_player.stream = rail_sound
					# Lower pitch for rails
					audio_player.pitch_scale = randf_range(0.7, 0.9)
				
				audio_player.volume_db = linear_to_db(clamp(impact_force / 8.0, 0.1, 1.0))
				audio_player.play()
				last_collision_time = Time.get_ticks_msec()

func _setup_audio():
	audio_player = AudioStreamPlayer3D.new()
	audio_player.unit_size = 5.0 
	add_child(audio_player)
	
	if ResourceLoader.exists("res://assets/sfx/ball_hit.wav"):
		hit_sound = load("res://assets/sfx/ball_hit.wav")
	if ResourceLoader.exists("res://assets/sfx/rail_hit.wav"):
		rail_sound = load("res://assets/sfx/rail_hit.wav")

func _setup_visuals():
	var sphere_mesh = SphereMesh.new()
	sphere_mesh.radius = 0.057 / 2.0
	sphere_mesh.height = 0.057
	sphere_mesh.radial_segments = 32
	sphere_mesh.rings = 16
	
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.mesh = sphere_mesh
	add_child(_mesh_instance)
	
	var shape = CollisionShape3D.new()
	var sphere_col = SphereShape3D.new()
	sphere_col.radius = 0.057 / 2.0
	shape.shape = sphere_col
	add_child(shape)
	
	_create_procedural_material(_ball_color)

func _create_procedural_material(color: Color):
	var mat = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.2
	mat.metallic = 0.0
	mat.specular = 0.5
	mat.clearcoat_enabled = true
	mat.clearcoat_roughness = 0.1
	_mesh_instance.material_override = mat
