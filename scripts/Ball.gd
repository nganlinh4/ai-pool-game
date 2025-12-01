class_name PoolBall
extends RigidBody2D

# --- AI & Physics Properties ---
var is_stopped: bool = true
const STOP_THRESHOLD: float = 5.0 # Pixels per second

func _ready():
	# 2D Top-down physics settings
	gravity_scale = 0.0
	linear_damp = 1.0 # Cloth friction
	angular_damp = 2.0
	
	# Create a physics material for bouncing if one doesn't exist
	if physics_material_override == null:
		var mat = PhysicsMaterial.new()
		mat.bounce = 0.8 # High bounce for billiard balls
		mat.friction = 0.1 # Low friction against other balls/walls
		physics_material_override = mat

	continuous_cd = RigidBody2D.CCD_MODE_CAST_RAY

func _physics_process(_delta):
	# Check if velocity is low enough to force stop
	if linear_velocity.length() < STOP_THRESHOLD:
		if not is_stopped:
			stop_ball()
	else:
		is_stopped = false

func stop_ball():
	is_stopped = true
	sleeping = true
	linear_velocity = Vector2.ZERO
	angular_velocity = 0.0

# --- Visual Helper (For Procedural Gen) ---
func set_color(color: Color):
	# Try to find an existing sprite or shape to color
	queue_redraw() # triggers _draw
	
# Simple debug drawing if no sprite is present
func _draw():
	if not get_node_or_null("Sprite2D"):
		draw_circle(Vector2.ZERO, 10.0, Color.WHITE if name == "CueBall" else Color(0.8, 0.2, 0.2))

# --- AI Observation Helper ---
func get_state_data() -> Dictionary:
	return {
		"position": [position.x, position.y],
		"velocity": [linear_velocity.x, linear_velocity.y],
		"name": name,
		"is_stopped": is_stopped
	}
