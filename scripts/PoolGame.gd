extends Node2D

# --- Configuration ---
@export var stick_line: Line2D
var cue_ball: RigidBody2D

# Game Settings
const TABLE_WIDTH = 800.0
const TABLE_HEIGHT = 400.0
const BALL_RADIUS = 10.0
const POCKET_RADIUS = 20.0
const MAX_POWER = 1500.0

# --- State ---
var is_turn_active: bool = false
var aim_angle: float = 0.0
var balls_on_table: Array[RigidBody2D] = []
var walls: StaticBody2D

# --- AI ---
@export var ai_controlled: bool = false
signal turn_ended

func _ready():
	# 1. Setup the Environment programmatically
	setup_table_boundaries()
	setup_pockets()
	setup_balls()
	setup_visuals()
	
	# Center the camera/view
	get_viewport().canvas_transform.origin = Vector2(get_viewport().size / 2) - Vector2(TABLE_WIDTH/2, TABLE_HEIGHT/2)

func _process(delta):
	queue_redraw() # Draw table background
	
	if not is_turn_active:
		if not ai_controlled:
			handle_human_input(delta)
		update_stick_visuals()
	else:
		if stick_line: stick_line.visible = false
		check_all_balls_stopped()

func _draw():
	# Draw Table Green Felt
	var rect = Rect2(0, 0, TABLE_WIDTH, TABLE_HEIGHT)
	draw_rect(rect, Color(0.0, 0.6, 0.2)) # Pool Table Green
	# Draw border outline
	draw_rect(rect, Color(0.4, 0.2, 0.0), false, 10.0) # Wood Brown

# --- 1. PROCEDURAL SETUP ---
func setup_table_boundaries():
	walls = StaticBody2D.new()
	walls.name = "TableWalls"
	# Bouncy walls
	var mat = PhysicsMaterial.new()
	mat.bounce = 0.8
	mat.friction = 0.2
	walls.physics_material_override = mat
	add_child(walls)
	
	# Create 4 walls
	var segments = [
		[Vector2(0,0), Vector2(TABLE_WIDTH, 0)], # Top
		[Vector2(TABLE_WIDTH, 0), Vector2(TABLE_WIDTH, TABLE_HEIGHT)], # Right
		[Vector2(TABLE_WIDTH, TABLE_HEIGHT), Vector2(0, TABLE_HEIGHT)], # Bottom
		[Vector2(0, TABLE_HEIGHT), Vector2(0,0)] # Left
	]
	
	for seg in segments:
		var shape = CollisionShape2D.new()
		var line_shape = SegmentShape2D.new()
		line_shape.a = seg[0]
		line_shape.b = seg[1]
		shape.shape = line_shape
		walls.add_child(shape)

func setup_pockets():
	# 6 Pockets positions
	var positions = [
		Vector2(0,0), Vector2(TABLE_WIDTH/2, 0), Vector2(TABLE_WIDTH, 0),
		Vector2(0, TABLE_HEIGHT), Vector2(TABLE_WIDTH/2, TABLE_HEIGHT), Vector2(TABLE_WIDTH, TABLE_HEIGHT)
	]
	
	for pos in positions:
		var pkt = Pocket.new()
		pkt.position = pos
		add_child(pkt)
		pkt.configure(POCKET_RADIUS)
		pkt.ball_potted.connect(_on_pocket_ball_potted)

func setup_balls():
	# 1. Cue Ball
	cue_ball = create_ball(Vector2(TABLE_WIDTH * 0.25, TABLE_HEIGHT * 0.5), "CueBall", Color.WHITE)
	
	# 2. Rack of 6 balls (Simple triangle)
	var start_x = TABLE_WIDTH * 0.75
	var start_y = TABLE_HEIGHT * 0.5
	var offset = BALL_RADIUS * 2.1
	
	var triangle_positions = [
		Vector2(0,0), 
		Vector2(1, -1), Vector2(1, 1),
		Vector2(2, -2), Vector2(2, 0), Vector2(2, 2)
	]
	
	var idx = 1
	for tri_pos in triangle_positions:
		var pos = Vector2(
			start_x + (tri_pos.x * offset * 0.866), # Hex packing X
			start_y + (tri_pos.y * offset * 0.5)    # Hex packing Y
		)
		create_ball(pos, "Ball_%d" % idx, Color.RED if idx % 2 == 0 else Color.YELLOW)
		idx += 1

func create_ball(pos: Vector2, b_name: String, color: Color) -> RigidBody2D:
	var ball = PoolBall.new()
	ball.name = b_name
	ball.position = pos
	
	# Add Collision Shape
	var col = CollisionShape2D.new()
	var shape = CircleShape2D.new()
	shape.radius = BALL_RADIUS
	col.shape = shape
	ball.add_child(col)
	
	add_child(ball)
	balls_on_table.append(ball)
	return ball

func setup_visuals():
	if not stick_line:
		stick_line = Line2D.new()
		stick_line.width = 4.0
		stick_line.default_color = Color(1, 1, 1, 0.5)
		add_child(stick_line)

# --- 2. INPUT & ACTIONS ---
func handle_human_input(delta):
	# Mouse Aiming
	if cue_ball and is_instance_valid(cue_ball):
		var mouse_pos = get_local_mouse_position() # Relative to Node2D
		var direction = mouse_pos - cue_ball.position
		aim_angle = direction.angle()
		
		if Input.is_action_just_pressed("shoot"):
			execute_shot(aim_angle, 1.0) # Full power for now

func update_stick_visuals():
	if not cue_ball or not is_instance_valid(cue_ball): 
		stick_line.visible = false
		return
	
	stick_line.visible = true
	stick_line.clear_points()
	var start = cue_ball.position
	var end = start + Vector2.from_angle(aim_angle) * 150.0
	stick_line.add_point(start)
	stick_line.add_point(end)

# --- 3. CORE LOGIC ---
func execute_shot(angle: float, power: float):
	if is_turn_active or not is_instance_valid(cue_ball): return
	
	print("Shot: %.2f rad, %.2f power" % [angle, power])
	is_turn_active = true
	cue_ball.sleeping = false
	cue_ball.apply_central_impulse(Vector2.from_angle(angle) * (power * MAX_POWER))

func check_all_balls_stopped():
	var any_moving = false
	for ball in balls_on_table:
		if is_instance_valid(ball) and not ball.is_stopped:
			any_moving = true
			break
	
	if not any_moving:
		is_turn_active = false
		print("Turn Ended.")
		emit_signal("turn_ended")
		if ai_controlled: request_ai_decision()

func _on_pocket_ball_potted(ball):
	print("Ball fell: ", ball.name)
	if ball == cue_ball:
		# Reset Cue Ball
		call_deferred("reset_cue_ball")
	else:
		balls_on_table.erase(ball)
		ball.queue_free()

func reset_cue_ball():
	cue_ball.stop_ball()
	cue_ball.position = Vector2(TABLE_WIDTH * 0.25, TABLE_HEIGHT * 0.5)

# --- 4. AI INTERFACE ---
func get_game_state() -> Dictionary:
	var balls_data = []
	for ball in balls_on_table:
		if is_instance_valid(ball):
			balls_data.append(ball.get_state_data())
			
	return {
		"table_size": [TABLE_WIDTH, TABLE_HEIGHT],
		"balls": balls_data,
		"is_turn_active": is_turn_active
	}

func request_ai_decision():
	# Dummy AI: Random shot
	await get_tree().create_timer(1.0).timeout
	execute_shot(randf() * TAU, randf_range(0.5, 1.0))
