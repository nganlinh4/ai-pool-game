class_name Pocket3D
extends Area3D

signal ball_potted(ball_node)

func _ready():
	body_entered.connect(_on_body_entered)

func _on_body_entered(body):
	if body is PoolBall3D:
		emit_signal("ball_potted", body)
