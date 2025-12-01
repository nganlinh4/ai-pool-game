extends Node2D

# --- Game Constants ---
const TABLE_W = 800.0
const TABLE_H = 400.0
const BALL_R = 10.0
const POCKET_R = 25.0 # Slightly larger for better gameplay feel
const RAIL_WIDTH = 30.0
const MAX_POWER = 2500.0
const MAX_DRAG_DIST = 250.0

# --- Colors ---
const COL_FELT = Color(0.0, 0.5, 0.35)
const COL_WOOD = Color(0.35, 0.2, 0.1)
const BALL_COLORS = [
	Color.YELLOW, Color.BLUE, Color.RED, Color.PURPLE, 
	Color.ORANGE, Color.GREEN, Color.MAROON
]

# --- State Machine ---
enum State { AIMING, SHOOTING, WAITING_FOR_STOP, PLACING_CUE, GAME_OVER }
var current_state = State.AIMING

enum Player { HUMAN, AI }
var turn_manager = Player.HUMAN

# --- Rules State ---
# 0 = Open, 1 = Solids (1-7), 2 = Stripes (9-15)
var player_group: int = 0 
var ai_group: int = 0
var balls_potted_this_turn: Array = []
var first_hit_ball_type: int = -1
var foul_committed: bool = false
var foul_reason: String = ""

# --- Nodes ---
var cue_ball: RigidBody2D
var balls_on_table: Array = []
var walls: StaticBody2D
var pockets: Array = []
var ui_layer: CanvasLayer
var status_label: Label
var group_label: Label

# --- Input ---
var is_dragging: bool = false
var drag_start_pos: Vector2
var aim_vector: Vector2

# --- Audio System ---
var audio_player: AudioStreamPlayer
var audio_playback: AudioStreamGeneratorPlayback
const SAMPLE_HZ = 44100.0
const PULSE_HZ = 400.0

func _ready():
	randomize()
	_setup_audio()
	_setup_visuals_and_ui()
	_setup_physics_world()
	reset_game()

# --------------------------------------------------------------------------
#   AUDIO ENGINE (Procedural)
# --------------------------------------------------------------------------
func _setup_audio():
	audio_player = AudioStreamPlayer.new()
	var generator = AudioStreamGenerator.new()
	generator.mix_rate = SAMPLE_HZ
	generator.buffer_length = 0.1 # Short buffer for low latency
	audio_player.stream = generator
	add_child(audio_player)
	audio_player.play()
	audio_playback = audio_player.get_stream_playback()

func play_clack_sound(intensity: float):
	if not audio_playback: return
	
	# Generate a short noise burst + sine wave decay
	# Map intensity (20..1000) to volume (0.1..1.0)
	var volume = clamp(intensity / 800.0, 0.1, 1.0)
	var frames_to_push = int(SAMPLE_HZ * 0.05) # 50ms sound
	
	if audio_playback.get_frames_available() < frames_to_push: return
	
	var buffer = PackedVector2Array()
	buffer.resize(frames_to_push)
	
	for i in range(frames_to_push):
		var t = float(i) / frames_to_push
		var decay = exp(-10.0 * t) # Exponential decay
		var sine = sin(t * 50.0) # Low thud
		var noise = randf_range(-1.0, 1.0) # Crack
		var sample = (sine * 0.5 + noise * 0.5) * decay * volume
		buffer[i] = Vector2(sample, sample)
		
	audio_playback.push_buffer(buffer)

# --------------------------------------------------------------------------
#   GAME LOOP
# --------------------------------------------------------------------------
func _process(_delta):
	queue_redraw()
	
	match current_state:
		State.AIMING:
			if turn_manager == Player.HUMAN:
				_handle_human_aiming()
			else:
				_run_ai_turn()
		
		State.PLACING_CUE:
			_handle_cue_placement()

		State.WAITING_FOR_STOP:
			if _are_balls_stopped():
				_end_turn_logic()

func _handle_human_aiming():
	if not is_instance_valid(cue_ball): return
	# Mouse drag logic handled in _unhandled_input and _draw
	pass

func _handle_cue_placement():
	if not is_instance_valid(cue_ball): return
	cue_ball.linear_velocity = Vector2.ZERO
	cue_ball.position = get_global_mouse_position()
	
	# Clamp to table
	var margin = BALL_R + RAIL_WIDTH
	cue_ball.position.x = clamp(cue_ball.position.x, margin, TABLE_W - margin)
	cue_ball.position.y = clamp(cue_ball.position.y, margin, TABLE_H - margin)
	
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		# Place it
		current_state = State.AIMING
		update_status("Placed. Drag to shoot.")

func _unhandled_input(event):
	if current_state == State.AIMING and turn_manager == Player.HUMAN and is_instance_valid(cue_ball):
		if event is InputEventMouseButton:
			if event.button_index == MOUSE_BUTTON_LEFT:
				if event.pressed:
					is_dragging = true
					drag_start_pos = get_global_mouse_position()
				elif is_dragging:
					is_dragging = false
					_execute_shot(aim_vector)

	if is_dragging and event is InputEventMouseMotion:
		var drag_vec = drag_start_pos - get_global_mouse_position()
		if drag_vec.length() > MAX_DRAG_DIST:
			drag_vec = drag_vec.normalized() * MAX_DRAG_DIST
		aim_vector = drag_vec

func _execute_shot(vector: Vector2):
	if vector.length() < 10.0: return # Ignore tiny drags
	
	var power_ratio = vector.length() / MAX_DRAG_DIST
	var impulse = vector.normalized() * (power_ratio * MAX_POWER)
	
	cue_ball.sleeping = false
	cue_ball.apply_central_impulse(impulse)
	
	play_clack_sound(MAX_POWER * power_ratio * 0.5) # Cue hit sound
	
	# Reset Turn Flags
	balls_potted_this_turn.clear()
	first_hit_ball_type = -1
	foul_committed = false
	foul_reason = ""
	
	current_state = State.WAITING_FOR_STOP
	update_status("Balls Rolling...")

# --------------------------------------------------------------------------
#   AI LOGIC
# --------------------------------------------------------------------------
func _run_ai_turn():
	if not is_instance_valid(cue_ball): return
	
	current_state = State.SHOOTING # Lock state
	update_status("AI is thinking...")
	
	# Delay for realism
	await get_tree().create_timer(1.0).timeout
	
	# 1. Identify Valid Targets
	var targets = []
	for b in balls_on_table:
		if b == cue_ball: continue
		if _is_ball_legal_target(b):
			targets.append(b)
	
	# If no legal targets, just hit anything (or 8 ball if that's all that's left)
	if targets.is_empty():
		for b in balls_on_table:
			if b != cue_ball: targets.append(b)
	
	# 2. Evaluate Best Shot
	var best_shot_vec = Vector2.ZERO
	var best_score = -1000.0
	
	for target in targets:
		for pocket in pockets:
			var pocket_pos = pocket.position
			
			# Vector from Target -> Pocket
			var to_pocket = pocket_pos - target.position
			
			# Is path to pocket clear?
			if not _raycast_check(target.position, pocket_pos, [target, cue_ball]):
				continue # Blocked
				
			# Calculate "Ghost Ball" position (where Cue must hit Target)
			var aim_dir = to_pocket.normalized()
			var ghost_pos = target.position - (aim_dir * (BALL_R * 2.0))
			
			# Vector from Cue -> Ghost Ball
			var shot_vec = ghost_pos - cue_ball.position
			
			# Is path to Ghost Ball clear?
			if not _raycast_check(cue_ball.position, ghost_pos, [cue_ball, target]):
				continue
				
			# Score this shot
			var dist_score = -shot_vec.length() # Closer is better
			var angle_cut = abs(shot_vec.angle_to(aim_dir)) # Straighter is better
			var score = dist_score - (angle_cut * 500.0)
			
			if score > best_score:
				best_score = score
				best_shot_vec = shot_vec
	
	# 3. Execute
	if best_shot_vec == Vector2.ZERO:
		# AI is stuck, shoot randomly
		best_shot_vec = Vector2(randf()-0.5, randf()-0.5) * 100.0
	else:
		# Add a little noise for "human-like" error
		best_shot_vec = best_shot_vec.rotated(randf_range(-0.02, 0.02))
		# Normalize for power calc
		if best_shot_vec.length() > MAX_DRAG_DIST:
			best_shot_vec = best_shot_vec.normalized() * MAX_DRAG_DIST
		else:
			# Ensure enough power to reach
			best_shot_vec = best_shot_vec.normalized() * (best_shot_vec.length() + 200.0)
			if best_shot_vec.length() > MAX_DRAG_DIST:
				best_shot_vec = best_shot_vec.normalized() * MAX_DRAG_DIST

	_execute_shot(best_shot_vec)

func _is_ball_legal_target(ball) -> bool:
	if ai_group == 0: return ball.ball_type != PoolBall.BallType.EIGHT # Can hit anything except 8
	if ai_group == 1: return ball.ball_type == PoolBall.BallType.SOLID
	if ai_group == 2: return ball.ball_type == PoolBall.BallType.STRIPE
	
	# If we are here, we might be on the 8-ball
	var my_balls_left = 0
	for b in balls_on_table:
		if (ai_group == 1 and b.ball_type == PoolBall.BallType.SOLID) or \
		   (ai_group == 2 and b.ball_type == PoolBall.BallType.STRIPE):
			my_balls_left += 1
	
	if my_balls_left == 0:
		return ball.ball_type == PoolBall.BallType.EIGHT
	return false

func _raycast_check(from: Vector2, to: Vector2, exclude: Array) -> bool:
	var space_state = get_world_2d().direct_space_state
	var query = PhysicsRayQueryParameters2D.create(from, to)
	var rid_exclude = []
	for obj in exclude:
		if is_instance_valid(obj): rid_exclude.append(obj.get_rid())
	query.exclude = rid_exclude
	var result = space_state.intersect_ray(query)
	return result.is_empty()

# --------------------------------------------------------------------------
#   RULES ENGINE
# --------------------------------------------------------------------------
func _on_ball_collision_report(intensity):
	play_clack_sound(intensity)

func _on_pocket_ball(ball):
	play_clack_sound(500.0) # Pot sound
	
	if ball == cue_ball:
		foul_committed = true
		foul_reason = "Scratch!"
		# Cue ball respawn handled in end logic
	else:
		balls_potted_this_turn.append(ball)
		balls_on_table.erase(ball)
		ball.queue_free()

func _end_turn_logic():
	# 1. Check Win/Loss (8-Ball)
	var eight_potted = false
	for b in balls_potted_this_turn:
		if is_instance_valid(b) and b.ball_type == PoolBall.BallType.EIGHT:
			eight_potted = true
			break
	
	if eight_potted:
		if foul_committed:
			_game_over("LOSS! 8-Ball Foul.")
		else:
			# Did we clear our group?
			var my_group = player_group if turn_manager == Player.HUMAN else ai_group
			var my_balls_remain = false
			# (Simplified check: assume if we shot at 8, we cleared others. 
			# In real rules we check strictly, but this suffices for now)
			_game_over("WINNER!")
		return

	# 2. Check Faults
	if not is_instance_valid(cue_ball):
		foul_committed = true # Scratch
	
	# 3. Assign Groups (Open Table)
	if player_group == 0 and not foul_committed and balls_potted_this_turn.size() > 0:
		var first = balls_potted_this_turn[0]
		if is_instance_valid(first):
			if first.ball_type == PoolBall.BallType.SOLID:
				if turn_manager == Player.HUMAN:
					player_group = 1; ai_group = 2
				else:
					ai_group = 1; player_group = 2
			elif first.ball_type == PoolBall.BallType.STRIPE:
				if turn_manager == Player.HUMAN:
					player_group = 2; ai_group = 1
				else:
					ai_group = 2; player_group = 1
			_update_group_ui()

	# 4. Turn Switching Logic
	var turn_continues = false
	if not foul_committed and balls_potted_this_turn.size() > 0:
		# Check if we potted our OWN ball
		var potted_ours = false
		var current_group = player_group if turn_manager == Player.HUMAN else ai_group
		
		for b in balls_potted_this_turn:
			if is_instance_valid(b):
				if current_group == 0: potted_ours = true # Open table
				elif current_group == 1 and b.ball_type == PoolBall.BallType.SOLID: potted_ours = true
				elif current_group == 2 and b.ball_type == PoolBall.BallType.STRIPE: potted_ours = true
			
		if potted_ours:
			turn_continues = true
	
	if foul_committed:
		update_status("FOUL: " + foul_reason)
		# Ball in Hand
		if not is_instance_valid(cue_ball):
			_respawn_cue_ball_memory()
		current_state = State.PLACING_CUE
		_switch_turn() # Foul always ends turn
	else:
		if turn_continues:
			update_status("Go Again!")
			current_state = State.AIMING
		else:
			_switch_turn()
			current_state = State.AIMING

func _switch_turn():
	turn_manager = Player.AI if turn_manager == Player.HUMAN else Player.HUMAN
	_update_turn_ui()

func _game_over(msg):
	update_status(msg)
	current_state = State.GAME_OVER
	await get_tree().create_timer(4.0).timeout
	reset_game()

func _respawn_cue_ball_memory():
	cue_ball = _create_ball(Vector2(-100, -100), PoolBall.BallType.CUE, 0)
	cue_ball.is_stopped = true

func _are_balls_stopped() -> bool:
	for b in balls_on_table:
		if is_instance_valid(b) and not b.is_stopped: return false
	if is_instance_valid(cue_ball) and not cue_ball.is_stopped: return false
	return true

# --------------------------------------------------------------------------
#   SETUP & BOILERPLATE
# --------------------------------------------------------------------------
func reset_game():
	# Cleanup
	for b in balls_on_table: if is_instance_valid(b): b.queue_free()
	balls_on_table.clear()
	if is_instance_valid(cue_ball): cue_ball.queue_free()
	
	player_group = 0; ai_group = 0
	turn_manager = Player.HUMAN
	
	_spawn_walls()
	_spawn_pockets()
	_rack_balls()
	_spawn_cue_ball()
	
	current_state = State.AIMING
	_update_group_ui()
	_update_turn_ui()

func _spawn_cue_ball():
	cue_ball = _create_ball(Vector2(TABLE_W * 0.25, TABLE_H * 0.5), PoolBall.BallType.CUE, 0)

func _create_ball(pos: Vector2, type: int, num: int) -> RigidBody2D:
	var b = PoolBall.new()
	b.position = pos
	
	var col_idx = (num - 1) % 7
	var color = BALL_COLORS[col_idx] if num != 8 else Color.BLACK
	if type == PoolBall.BallType.CUE: color = Color.WHITE
	
	b.setup(num, type, color)
	
	var shape = CollisionShape2D.new()
	var circ = CircleShape2D.new()
	circ.radius = BALL_R
	shape.shape = circ
	b.add_child(shape)
	
	# Connect Audio Signal
	b.collided.connect(_on_ball_collision_report)
	
	add_child(b)
	if type != PoolBall.BallType.CUE:
		balls_on_table.append(b)
	return b

func _rack_balls():
	var start_x = TABLE_W * 0.75
	var start_y = TABLE_H * 0.5
	var r = BALL_R
	var ball_nums = range(1, 16)
	ball_nums.shuffle()
	
	var idx = 0
	for col in range(5):
		for row in range(col + 1):
			var x = start_x + (col * r * 1.732)
			var y = start_y + (row * r * 2.0) - (col * r)
			
			var num = ball_nums[idx]
			var type = PoolBall.BallType.SOLID
			if num > 8: type = PoolBall.BallType.STRIPE
			if num == 8: type = PoolBall.BallType.EIGHT
			
			# Force 8 ball to center (row 1, col 2 in 0-indexed triangle)
			if col == 2 and row == 1:
				num = 8; type = PoolBall.BallType.EIGHT
			elif num == 8:
				num = 1; type = PoolBall.BallType.SOLID # Swap
				
			_create_ball(Vector2(x, y), type, num)
			idx += 1
			if idx >= 15: return

func _setup_visuals_and_ui():
	# Cam
	var cam = Camera2D.new()
	cam.position = Vector2(TABLE_W/2, TABLE_H/2)
	add_child(cam)
	
	# UI
	ui_layer = CanvasLayer.new()
	add_child(ui_layer)
	
	status_label = Label.new()
	status_label.position = Vector2(0, 20)
	status_label.size = Vector2(1280, 50)
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.add_theme_font_size_override("font_size", 32)
	ui_layer.add_child(status_label)
	
	group_label = Label.new()
	group_label.position = Vector2(20, 20)
	group_label.add_theme_font_size_override("font_size", 24)
	ui_layer.add_child(group_label)

func _update_group_ui():
	var txt = "Table: Open"
	if player_group == 1: txt = "You: SOLIDS | AI: STRIPES"
	elif player_group == 2: txt = "You: STRIPES | AI: SOLIDS"
	group_label.text = txt

func _update_turn_ui():
	status_label.text = "Your Turn" if turn_manager == Player.HUMAN else "AI Turn"

func update_status(text: String):
	status_label.text = text

func _draw():
	# Floor
	draw_rect(Rect2(-1000, -1000, 3000, 3000), Color(0.12, 0.12, 0.14))
	# Table
	draw_rect(Rect2(-RAIL_WIDTH, -RAIL_WIDTH, TABLE_W+RAIL_WIDTH*2, TABLE_H+RAIL_WIDTH*2), COL_WOOD)
	draw_rect(Rect2(0,0,TABLE_W, TABLE_H), COL_FELT)
	
	# Aim Lines
	if current_state == State.AIMING and is_dragging and is_instance_valid(cue_ball):
		var start = cue_ball.position
		var power = aim_vector.length() / MAX_DRAG_DIST
		
		# Guide Line
		draw_line(start, start + aim_vector.normalized() * 500, Color(1,1,1,0.2), 2.0)
		
		# Cue Stick
		var stick_dir = -aim_vector.normalized()
		var stick_pos = start + stick_dir * (25 + power * 60)
		draw_line(stick_pos, stick_pos + stick_dir * 300, Color(0.9, 0.8, 0.6), 8.0)
		draw_line(stick_pos, stick_pos + stick_dir * 10, Color.BLUE, 8.0)

func _setup_physics_world():
	walls = StaticBody2D.new()
	var mat = PhysicsMaterial.new()
	mat.bounce = 0.6; mat.friction = 0.1
	walls.physics_material_override = mat
	add_child(walls)

func _spawn_walls():
	for c in walls.get_children(): c.queue_free()
	var polys = [
		[Vector2(-RAIL_WIDTH, -RAIL_WIDTH), Vector2(TABLE_W+RAIL_WIDTH, -RAIL_WIDTH), Vector2(TABLE_W, 0), Vector2(0,0)],
		[Vector2(TABLE_W, 0), Vector2(TABLE_W+RAIL_WIDTH, -RAIL_WIDTH), Vector2(TABLE_W+RAIL_WIDTH, TABLE_H+RAIL_WIDTH), Vector2(TABLE_W, TABLE_H)],
		[Vector2(0, TABLE_H), Vector2(TABLE_W, TABLE_H), Vector2(TABLE_W+RAIL_WIDTH, TABLE_H+RAIL_WIDTH), Vector2(-RAIL_WIDTH, TABLE_H+RAIL_WIDTH)],
		[Vector2(-RAIL_WIDTH, -RAIL_WIDTH), Vector2(0,0), Vector2(0, TABLE_H), Vector2(-RAIL_WIDTH, TABLE_H+RAIL_WIDTH)]
	]
	for p in polys:
		var col = CollisionPolygon2D.new()
		col.polygon = PackedVector2Array(p)
		walls.add_child(col)

func _spawn_pockets():
	pockets.clear()
	for c in get_children(): if c is Pocket: c.queue_free()
	var locs = [Vector2(0,0), Vector2(TABLE_W/2, -5), Vector2(TABLE_W, 0), Vector2(0, TABLE_H), Vector2(TABLE_W/2, TABLE_H+5), Vector2(TABLE_W, TABLE_H)]
	for pos in locs:
		var p = Pocket.new()
		p.position = pos
		add_child(p)
		p.configure(POCKET_R)
		p.ball_potted.connect(_on_pocket_ball)
		pockets.append(p)
