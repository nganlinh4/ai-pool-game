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
	circle.radius = radius
	shape.shape = circle
	add_child(shape)
	queue_redraw()

func _on_body_entered(body):
	if body is PoolBall:
		emit_signal("ball_potted", body)

func _draw():
	# Visual debug for the hole
	draw_circle(Vector2.ZERO, 20.0, Color(0.1, 0.1, 0.1)) # Dark grey hole
