extends Node3D

# --- Constants ---
const TABLE_WIDTH = 2.24
const TABLE_LENGTH = 1.12
const BALL_RADIUS = 0.057 / 2.0
const MAX_POWER_IMPULSE = 35.0 # Increased for "Power Shot" feel
const MOUSE_SENSITIVITY = 0.002

# --- State ---
enum State { AIMING, CHARGING, SHOOTING, WAITING_FOR_STOP, GAME_OVER }
var current_state = State.AIMING
var balls_on_table: Array[PoolBall3D] = []
var cue_ball: PoolBall3D
var pockets: Array[Pocket3D] = []

# --- Rules State ---
var player_turn = 1
var assigned_type_p1 = -1 # 0: Solid, 1: Stripe, -1: Open
var foul_occured = false
var game_message = ""

# --- Nodes ---
var camera_rig: Node3D
var camera: Camera3D
var cue_stick: CueStick
var ghost_ball: MeshInstance3D
var aim_line: MeshInstance3D
@onready var ui_status: Label = $CanvasLayer/StatusLabel
@onready var power_bar: ProgressBar = $CanvasLayer/PowerBar

# --- Input State ---
var current_yaw: float = 0.0
var current_pitch: float = -0.5
var charge_power: float = 0.0
var charging_dir: int = 1

func _ready():
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	
	_setup_environment()
	_setup_table_geometry()
	_spawn_balls()
	_setup_camera()
	_setup_aim_helpers()
	
	cue_stick = CueStick.new()
	add_child(cue_stick)
	
	_update_status_ui()

func _input(event):
	if current_state == State.AIMING or current_state == State.CHARGING:
		if event is InputEventMouseMotion:
			current_yaw -= event.relative.x * MOUSE_SENSITIVITY
			current_pitch -= event.relative.y * MOUSE_SENSITIVITY
			current_pitch = clamp(current_pitch, -1.2, -0.1)
			
			camera_rig.rotation.y = current_yaw
			camera.rotation.x = current_pitch
			
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED

func _process(delta):
	if is_instance_valid(cue_ball):
		camera_rig.position = camera_rig.position.lerp(cue_ball.position, delta * 15.0)
	
	match current_state:
		State.AIMING:
			_handle_aiming(delta)
			if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
				current_state = State.CHARGING
				charge_power = 0.0
				
		State.CHARGING:
			_handle_charging(delta)
			if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
				_shoot()

		State.WAITING_FOR_STOP:
			cue_stick.visible = false
			ghost_ball.visible = false
			aim_line.visible = false
			if _are_balls_stopped():
				_process_turn_rules()

func _handle_aiming(_delta):
	cue_stick.visible = true
	ghost_ball.visible = false
	aim_line.visible = true
	
	# Calculate aim direction from camera rig
	var aim_dir = -camera_rig.basis.z.normalized()
	aim_dir.y = 0
	aim_dir = aim_dir.normalized()
	
	# Update Cue Stick Visual
	cue_stick.update_transform(cue_ball.position, aim_dir, current_pitch, 0.0)
	
	# Raycast for Ghost Ball
	var space = get_world_3d().direct_space_state
	var param = PhysicsShapeQueryParameters3D.new()
	var sphere = SphereShape3D.new()
	sphere.radius = BALL_RADIUS
	param.shape = sphere
	param.transform = Transform3D(Basis(), cue_ball.position)
	param.motion = aim_dir * 3.0 # Look ahead 3 meters
	param.exclude = [cue_ball.get_rid()]
	
	var result = space.cast_motion(param)
	# cast_motion returns [safe_fraction, unsafe_fraction]
	
	if result[1] < 1.0:
		# We hit something
		var hit_dist = result[1] * 3.0
		var ghost_pos = cue_ball.position + (aim_dir * hit_dist)
		
		# Show Ghost Ball
		ghost_ball.visible = true
		ghost_ball.position = ghost_pos
		
		# Draw line to ghost ball
		_draw_aim_line(cue_ball.position, ghost_pos)
	else:
		_draw_aim_line(cue_ball.position, cue_ball.position + aim_dir * 1.0)

func _handle_charging(delta):
	charge_power += delta * 1.5 * charging_dir
	if charge_power >= 1.0:
		charge_power = 1.0
		charging_dir = -1
	elif charge_power <= 0.0:
		charge_power = 0.0
		charging_dir = 1
		
	# Animate Cue Stick pulling back
	var aim_dir = -camera_rig.basis.z.normalized()
	aim_dir.y = 0
	cue_stick.update_transform(cue_ball.position, aim_dir.normalized(), current_pitch, charge_power * 0.5)
	
	if power_bar: power_bar.value = charge_power * 100

func _shoot():
	if not is_instance_valid(cue_ball): return
	
	var impulse = charge_power * MAX_POWER_IMPULSE
	var shot_dir = -camera_rig.basis.z.normalized()
	shot_dir.y = 0
	shot_dir = shot_dir.normalized()
	
	cue_ball.launch(shot_dir * impulse)
	
	current_state = State.WAITING_FOR_STOP
	ui_status.text = "Rolling..."
	if power_bar: power_bar.value = 0

# --- Visuals ---

func _setup_aim_helpers():
	# Aim Line
	aim_line = MeshInstance3D.new()
	var imm_mesh = ImmediateMesh.new()
	aim_line.mesh = imm_mesh
	aim_line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(aim_line)
	
	# Ghost Ball
	ghost_ball = MeshInstance3D.new()
	var sph = SphereMesh.new()
	sph.radius = BALL_RADIUS
	sph.height = BALL_RADIUS * 2
	ghost_ball.mesh = sph
	
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(1, 1, 1, 0.4) # Transparent White
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(1, 1, 1)
	mat.emission_energy_multiplier = 0.5
	ghost_ball.material_override = mat
	add_child(ghost_ball)

func _draw_aim_line(from: Vector3, to: Vector3):
	var mesh = aim_line.mesh as ImmediateMesh
	mesh.clear_surfaces()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	mesh.surface_set_color(Color(1, 1, 1, 0.8))
	mesh.surface_add_vertex(from)
	mesh.surface_set_color(Color(1, 1, 1, 0.2))
	mesh.surface_add_vertex(to)
	mesh.surface_end()

func _setup_camera():
	camera_rig = Node3D.new()
	add_child(camera_rig)
	camera = Camera3D.new()
	camera.position = Vector3(0, 1.6, 2.2) 
	camera_rig.add_child(camera)
	camera_rig.rotation.y = PI / 2.0 # Start from side
	current_yaw = PI / 2.0

func _setup_environment():
	var env = WorldEnvironment.new()
	var environment = Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.05, 0.05, 0.05) # Dark room
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.ssr_enabled = true # Reflections
	environment.ssao_enabled = true 
	environment.glow_enabled = true
	environment.glow_intensity = 0.5
	env.environment = environment
	add_child(env)
	
	# Spotlight over table (Pool Hall vibe)
	var spot = SpotLight3D.new()
	spot.position = Vector3(0, 3, 0)
	spot.rotation.x = -PI / 2
	spot.spot_angle = 60
	spot.light_energy = 8.0
	spot.shadow_enabled = true
	add_child(spot)

# --- Game Rules Engine ---

func _are_balls_stopped() -> bool:
	if not is_instance_valid(cue_ball): return true
	if not cue_ball.is_stopped: return false
	for b in balls_on_table:
		if is_instance_valid(b) and not b.is_stopped: return false
	return true

func _process_turn_rules():
	# Simplified 8-Ball Rules
	var ball_potted_this_turn = false
	var wrong_ball_potted = false
	var foul = false
	
	# Check cue ball
	if not is_instance_valid(cue_ball):
		foul = true
		_respawn_cue_ball()
		game_message = "Scratch! Cue Ball Potted."
	
	# In a real implementation, we would track exactly WHICH balls were potted this turn
	# For now, we assume if count changed, something was potted.
	
	if foul:
		_switch_turn()
	else:
		_switch_turn() # Default turn switch for prototype
	
	current_state = State.AIMING
	_update_status_ui()

func _respawn_cue_ball():
	cue_ball = PoolBall3D.new()
	cue_ball.setup(0, PoolBall3D.BallType.CUE, Color.WHITE)
	cue_ball.position = Vector3(-TABLE_WIDTH/4.0, BALL_RADIUS, 0)
	add_child(cue_ball)

func _switch_turn():
	player_turn = 3 - player_turn # Toggle 1 -> 2, 2 -> 1
	game_message = ""

func _update_status_ui():
	var p_type = "Open"
	if assigned_type_p1 != -1:
		if player_turn == 1: p_type = "Solids" if assigned_type_p1 == 0 else "Stripes"
		else: p_type = "Stripes" if assigned_type_p1 == 0 else "Solids"
	
	ui_status.text = "Player %d Turn (%s)\n%s" % [player_turn, p_type, game_message]

# --- Geometry Generation (Visuals) ---

func _setup_table_geometry():
	var table_root = Node3D.new()
	add_child(table_root)
	
	# Pockets
	var pocket_positions = [
		Vector3(-TABLE_WIDTH/2, 0, -TABLE_LENGTH/2), Vector3(TABLE_WIDTH/2, 0, -TABLE_LENGTH/2),
		Vector3(-TABLE_WIDTH/2, 0, TABLE_LENGTH/2), Vector3(TABLE_WIDTH/2, 0, TABLE_LENGTH/2),
		Vector3(-TABLE_WIDTH/2, 0, 0), Vector3(TABLE_WIDTH/2, 0, 0)
	]
	
	# Felt Surface
	var floor_body = StaticBody3D.new()
	var floor_col = CollisionShape3D.new()
	var floor_box = BoxShape3D.new()
	floor_box.size = Vector3(TABLE_WIDTH, 0.1, TABLE_LENGTH)
	floor_col.shape = floor_box
	floor_col.position.y = -0.05
	floor_body.add_child(floor_col)
	
	var floor_vis = CSGBox3D.new()
	floor_vis.size = floor_box.size
	floor_vis.position.y = -0.05
	var mat_felt = StandardMaterial3D.new()
	mat_felt.albedo_color = Color(0.0, 0.35, 0.15) # Darker rich green
	mat_felt.roughness = 1.0
	floor_vis.material = mat_felt
	floor_body.add_child(floor_vis)
	table_root.add_child(floor_body)
	
	# Setup Pockets
	for pos in pocket_positions:
		var p = Pocket3D.new()
		p.position = pos
		var col = CollisionShape3D.new()
		var cyl = CylinderShape3D.new()
		cyl.radius = 0.13
		cyl.height = 0.2
		col.shape = cyl
		p.add_child(col)
		p.ball_potted.connect(_on_ball_potted)
		table_root.add_child(p)
		
		# Visual Black Hole for pocket
		var mesh = MeshInstance3D.new()
		var p_cyl = CylinderMesh.new()
		p_cyl.top_radius = 0.11
		p_cyl.bottom_radius = 0.1
		p_cyl.height = 0.01
		mesh.mesh = p_cyl
		mesh.position = pos
		mesh.position.y = 0.01
		var p_mat = StandardMaterial3D.new()
		p_mat.albedo_color = Color.BLACK
		mesh.material_override = p_mat
		table_root.add_child(mesh)
	
	# Wooden Frame Rails
	_create_cushion_rail(Vector3(0, 0, -TABLE_LENGTH/2 - 0.1), Vector3(TABLE_WIDTH + 0.4, 0.15, 0.2), table_root)
	_create_cushion_rail(Vector3(0, 0, TABLE_LENGTH/2 + 0.1), Vector3(TABLE_WIDTH + 0.4, 0.15, 0.2), table_root)
	_create_cushion_rail(Vector3(-TABLE_WIDTH/2 - 0.1, 0, 0), Vector3(0.2, 0.15, TABLE_LENGTH + 0.2), table_root)
	_create_cushion_rail(Vector3(TABLE_WIDTH/2 + 0.1, 0, 0), Vector3(0.2, 0.15, TABLE_LENGTH + 0.2), table_root)

func _create_cushion_rail(pos: Vector3, size: Vector3, parent):
	var body = StaticBody3D.new()
	body.position = pos
	
	var shape = CollisionShape3D.new()
	var box = BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	
	var vis = CSGBox3D.new()
	vis.size = size
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.25, 0.15, 0.05) # Dark polished wood
	mat.roughness = 0.3
	mat.specular = 0.5
	vis.material = mat
	body.add_child(vis)
	
	parent.add_child(body)

func _spawn_balls():
	balls_on_table.clear()
	var start_pos = Vector3(TABLE_WIDTH/4.0, BALL_RADIUS, 0)
	var rows = 5
	var count = 1
	var spacing = BALL_RADIUS * 2.01
	
	for col in range(rows):
		for row in range(col + 1):
			var z = (row * spacing) - (col * spacing / 2.0)
			var x = start_pos.x + (col * spacing * 0.866)
			
			var b = PoolBall3D.new()
			# Determine Solid/Stripe/8
			var type = PoolBall3D.BallType.SOLID
			if count > 8: type = PoolBall3D.BallType.STRIPE
			if count == 8: type = PoolBall3D.BallType.EIGHT
			
			b.setup(count, type, _get_ball_color(count))
			b.position = Vector3(x, BALL_RADIUS, z)
			add_child(b)
			balls_on_table.append(b)
			count += 1

	cue_ball = PoolBall3D.new()
	cue_ball.setup(0, PoolBall3D.BallType.CUE, Color.WHITE)
	cue_ball.position = Vector3(-TABLE_WIDTH/4.0, BALL_RADIUS, 0)
	add_child(cue_ball)

func _get_ball_color(num: int) -> Color:
	if num == 8: return Color.BLACK
	var colors = [Color.YELLOW, Color.BLUE, Color.RED, Color.PURPLE, Color.ORANGE, Color(0, 0.5, 0), Color.MAROON]
	var idx = (num - 1) % 8
	if idx < colors.size(): return colors[idx]
	return Color.BLACK

func _on_ball_potted(ball):
	if ball == cue_ball:
		ball.linear_velocity = Vector3.ZERO
		ball.angular_velocity = Vector3.ZERO
		ball.position = Vector3(0, -10, 0) # Move out of way
		ball.queue_free() # Will be respawned
	else:
		balls_on_table.erase(ball)
		ball.queue_free()
