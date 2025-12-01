class_name Pocket
extends Area2D

signal ball_potted(ball_node)

func _ready():
	body_entered.connect(_on_body_entered)
	monitorable = false
	monitoring = true

func configure(radius: float):
	var shape = CollisionShape2D.new()
	var circle = CircleShape2D.new()
	circle.radius = radius * 0.8 # Hitbox slightly smaller than visual
	shape.shape = circle
	add_child(shape)
	queue_redraw()

func _on_body_entered(body):
	if body is PoolBall:
		emit_signal("ball_potted", body)

func _draw():
	# Outer rim (Table trim)
	draw_circle(Vector2.ZERO, 24.0, Color(0.2, 0.1, 0.05)) 
	# The Hole
	draw_circle(Vector2.ZERO, 18.0, Color(0.05, 0.05, 0.05))
	# Inner shadow
	draw_circle(Vector2(-2, -2), 16.0, Color(0.0, 0.0, 0.0))
