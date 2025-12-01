class_name PoolBall
extends RigidBody2D

# --- Properties ---
enum BallType { CUE, SOLID, STRIPE, EIGHT }

var ball_type: int = BallType.SOLID
var ball_number: int = 0
var main_color: Color = Color.WHITE

var is_stopped: bool = true
const STOP_THRESHOLD: float = 5.0 

# To prevent race conditions where ball stops before physics impulse kicks in
var _grace_period: float = 0.0

# Rules tracking
var first_collision_body: Node = null

# Signals
signal collided(intensity, position)

# Visuals
var _visual_node: Node2D
var _number_label: Label

func _ready():
	# Physics Setup
	gravity_scale = 0.0
	linear_damp = 0.8 
	angular_damp = 1.5
	
	# Enable Collision Reporting for Audio & Rules
	contact_monitor = true
	max_contacts_reported = 2
	
	if physics_material_override == null:
		var mat = PhysicsMaterial.new()
		mat.bounce = 0.9 
		mat.friction = 0.2
		physics_material_override = mat

	continuous_cd = RigidBody2D.CCD_MODE_CAST_RAY
	
	_setup_visuals()

func setup(number: int, type: int, color: Color):
	ball_number = number
	ball_type = type
	main_color = color
	
	if _visual_node:
		_visual_node.queue_redraw()
	
	if _number_label:
		_number_label.text = str(number) if number > 0 else ""
		_number_label.visible = (type != BallType.CUE)

func reset_turn_state():
	first_collision_body = null

func launch(impulse: Vector2):
	reset_turn_state()
	sleeping = false
	is_stopped = false
	apply_central_impulse(impulse)
	# Force "active" state for 0.2s to allow physics engine to catch up
	# This prevents the "Hit Nothing" foul immediately after shooting
	_grace_period = 0.2

func _setup_visuals():
	if _visual_node == null:
		_visual_node = Node2D.new()
		_visual_node.draw.connect(_on_visual_draw)
		add_child(_visual_node)
		
		# Add Number Label
		_number_label = Label.new()
		_number_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_number_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_number_label.add_theme_color_override("font_color", Color.BLACK)
		_number_label.add_theme_font_size_override("font_size", 10)
		_number_label.size = Vector2(20, 20)
		_number_label.position = Vector2(-10, -11) # Center it
		_visual_node.add_child(_number_label)

func _physics_process(delta):
	# Rolling friction logic - stops infinite tiny drifting
	
	if _grace_period > 0.0:
		_grace_period -= delta
		is_stopped = false
	elif linear_velocity.length() < STOP_THRESHOLD:
		if not is_stopped:
			stop_ball()
	else:
		is_stopped = false
	
	if not is_stopped:
		var speed = linear_velocity.length()
		# Rotate visual node based on movement to simulate 3D roll
		_visual_node.rotation += speed * delta * 0.05

func _integrate_forces(state):
	if state.get_contact_count() > 0:
		var my_vel = state.linear_velocity
		
		for i in range(state.get_contact_count()):
			var collider = state.get_contact_collider_object(i)
			
			# Logic: Record first ball hit for rules
			if first_collision_body == null and collider is PoolBall:
				first_collision_body = collider
			
			# Audio / Particles Logic
			var col_vel = state.get_contact_collider_velocity_at_position(i)
			var impact = (my_vel - col_vel).length()
			
			if impact > 20.0:
				var local_pos = state.get_contact_local_position(i)
				var global_pos = global_transform * local_pos
				emit_signal("collided", impact, global_pos)

func stop_ball():
	is_stopped = true
	sleeping = true
	linear_velocity = Vector2.ZERO
	angular_velocity = 0.0

func _on_visual_draw():
	var r = 10.0
	
	# --- 1. Draw Shadow ---
	# FIX: Shadow must NOT rotate with the ball.
	var shadow_offset = Vector2(4, 4).rotated(-_visual_node.rotation)
	_visual_node.draw_circle(shadow_offset, r, Color(0,0,0, 0.3))
	
	# --- 2. Base Color ---
	var draw_col = main_color
	if ball_type == BallType.CUE: draw_col = Color(0.95, 0.95, 0.95)
	if ball_type == BallType.EIGHT: draw_col = Color(0.1, 0.1, 0.1)
	
	_visual_node.draw_circle(Vector2.ZERO, r, draw_col)
	
	# --- 3. Stripe ---
	if ball_type == BallType.STRIPE:
		# Draw white cheeks
		_visual_node.draw_circle(Vector2.ZERO, r, Color.WHITE)
		# Draw colored band
		var rect = Rect2(-r, -r*0.6, r*2, r*1.2)
		_visual_node.draw_rect(rect, main_color)
	
	# --- 4. Number Circle (White background for number) ---
	if ball_type != BallType.CUE:
		var circle_col = Color(0.9, 0.9, 0.9)
		if ball_type == BallType.EIGHT: circle_col = Color.WHITE
		_visual_node.draw_circle(Vector2.ZERO, r * 0.45, circle_col)
	
	# --- 5. 3D Shininess (Glint) ---
	_visual_node.draw_circle(Vector2(-3, -3), r * 0.6, Color(1, 1, 1, 0.1))
	_visual_node.draw_circle(Vector2(-4, -4), r * 0.3, Color(1, 1, 1, 0.3))
	_visual_node.draw_circle(Vector2(-5, -5), r * 0.15, Color(1, 1, 1, 0.7))

func get_state_data() -> Dictionary:
	return {
		"position": position,
		"type": ball_type,
		"stopped": is_stopped,
		"number": ball_number
	}
