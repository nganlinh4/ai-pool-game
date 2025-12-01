class_name PoolBall
extends RigidBody2D

# --- Properties ---
enum BallType { CUE, SOLID, STRIPE, EIGHT }

var ball_type: int = BallType.SOLID
var ball_number: int = 0
var main_color: Color = Color.WHITE

var is_stopped: bool = true
const STOP_THRESHOLD: float = 5.0 

# Signals
signal collided(intensity)

# Visuals
var _visual_node: Node2D

func _ready():
	# Physics Setup
	gravity_scale = 0.0
	linear_damp = 1.0 
	angular_damp = 2.0 
	
	# Enable Collision Reporting for Audio
	contact_monitor = true
	max_contacts_reported = 2
	
	if physics_material_override == null:
		var mat = PhysicsMaterial.new()
		mat.bounce = 0.85 
		mat.friction = 0.3
		physics_material_override = mat

	continuous_cd = RigidBody2D.CCD_MODE_CAST_RAY
	
	# Setup Visuals
	if _visual_node == null:
		_visual_node = Node2D.new()
		_visual_node.script = null
		_visual_node.draw.connect(_on_visual_draw)
		add_child(_visual_node)

func setup(number: int, type: int, color: Color):
	ball_number = number
	ball_type = type
	main_color = color
	if _visual_node == null:
		_visual_node = Node2D.new()
		_visual_node.script = null
		_visual_node.draw.connect(_on_visual_draw)
		add_child(_visual_node)
	_visual_node.queue_redraw()

func _physics_process(_delta):
	# Rolling friction logic
	if linear_velocity.length() < STOP_THRESHOLD:
		if not is_stopped:
			stop_ball()
	else:
		is_stopped = false
		var speed = linear_velocity.length()
		_visual_node.rotation += speed * _delta * 0.05

func _integrate_forces(state):
	# Detect collisions for Audio
	if state.get_contact_count() > 0:
		# Sum up impact forces (approximate via velocity difference)
		# Note: In a real engine we'd look at impulse, but velocity is a decent proxy here
		var my_vel = state.linear_velocity
		for i in range(state.get_contact_count()):
			var col_vel = state.get_contact_collider_velocity_at_position(i)
			# Impact intensity roughly proportional to relative velocity
			var impact = (my_vel - col_vel).length()
			if impact > 20.0: # Minimum sound threshold
				emit_signal("collided", impact)

func stop_ball():
	is_stopped = true
	sleeping = true
	linear_velocity = Vector2.ZERO
	angular_velocity = 0.0
	_visual_node.rotation = 0 

func _on_visual_draw():
	var r = 10.0
	
	# Shadow
	_visual_node.draw_circle(Vector2(3, 3), r, Color(0,0,0, 0.2))
	
	# Base
	var draw_col = main_color
	if ball_type == BallType.CUE: draw_col = Color.WHITE
	if ball_type == BallType.EIGHT: draw_col = Color.BLACK
	
	_visual_node.draw_circle(Vector2.ZERO, r, draw_col)
	
	# Stripes
	if ball_type == BallType.STRIPE:
		_visual_node.draw_circle(Vector2.ZERO, r, Color.WHITE)
		var rect = Rect2(-r, -r*0.6, r*2, r*1.2)
		_visual_node.draw_rect(rect, main_color)
	
	# Number Circle
	if ball_type != BallType.CUE:
		_visual_node.draw_circle(Vector2.ZERO, r * 0.5, Color.WHITE)
		# We don't render text to keep it simple/fast without a Label node
	
	# Highlight
	_visual_node.draw_circle(Vector2(-3, -3), r * 0.3, Color(1,1,1, 0.5))

func get_state_data() -> Dictionary:
	return {
		"position": position,
		"type": ball_type,
		"stopped": is_stopped,
		"number": ball_number
	}
