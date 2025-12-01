extends Node2D

# --- Game Constants ---
const TABLE_W = 800.0
const TABLE_H = 400.0
const BALL_R = 10.0
const POCKET_R = 25.0
const RAIL_WIDTH = 30.0
const MAX_POWER = 2500.0
const MAX_DRAG_DIST = 250.0

# --- Colors ---
const COL_FELT = Color(0.0, 0.5, 0.35)
const COL_FELT_DARK = Color(0.0, 0.45, 0.32)
const COL_WOOD = Color(0.35, 0.2, 0.1)
const COL_WOOD_DARK = Color(0.25, 0.15, 0.05)
# Standard Pool Colors: 1-Yellow, 2-Blue, 3-Red, 4-Purple, 5-Orange, 6-Green, 7-Maroon
const BALL_COLORS = [
	Color.YELLOW, Color.BLUE, Color.RED, Color.PURPLE, 
	Color(1, 0.5, 0), Color.GREEN, Color(0.5, 0, 0)
]

# --- State Machine ---
enum State { MENU, AIMING, SHOOTING, WAITING_FOR_STOP, PLACING_CUE, GAME_OVER }
var current_state = State.MENU

enum Player { HUMAN, AI }
var turn_manager = Player.HUMAN
var game_mode = Player.AI

# --- Rules State ---
var player_group: int = 0  # 0: Open, 1: Solids, 2: Stripes
var ai_group: int = 0
var balls_potted_this_turn: Array = []
var foul_committed: bool = false
var foul_reason: String = ""

# --- Nodes ---
var cue_ball: RigidBody2D
var balls_on_table: Array = []
var walls: StaticBody2D
var pockets: Array = []
var particle_container: Node2D 

# UI Nodes
var ui_layer: CanvasLayer
var menu_control: Control
var hud_control: Control
var status_label: Label
var group_label: Label

# Camera
var camera: Camera2D
var shake_strength: float = 0.0

# --- Input & Aiming ---
var is_dragging: bool = false
var drag_start_pos: Vector2
var aim_vector: Vector2
var ghost_ball_pos: Vector2 = Vector2.INF
var ghost_target_path: Vector2 = Vector2.ZERO

# --- Audio System ---
var audio_player: AudioStreamPlayer
var audio_playback: AudioStreamGeneratorPlayback
const SAMPLE_HZ = 44100.0

func _ready():
	randomize()
	_setup_audio()
	_setup_camera()
	_setup_ui_system()
	_setup_physics_world()
	
	particle_container = Node2D.new()
	add_child(particle_container)
	
	# Start in Menu
	_set_state(State.MENU)

# --------------------------------------------------------------------------
#   GAME LOOP & PROCESS
# --------------------------------------------------------------------------
func _process(delta):
	queue_redraw()
	_process_camera_shake(delta)
	
	match current_state:
		State.MENU:
			pass 
		State.AIMING:
			if turn_manager == Player.HUMAN:
				_handle_human_aiming()
			elif game_mode == Player.AI:
				_run_ai_turn()
		State.PLACING_CUE:
			_handle_cue_placement()
		State.WAITING_FOR_STOP:
			if _are_balls_stopped():
				_end_turn_logic()

func _set_state(new_state):
	current_state = new_state
	menu_control.visible = (new_state == State.MENU)
	hud_control.visible = (new_state != State.MENU)
	
	if new_state == State.MENU:
		_clear_table_entities()
	
	if new_state == State.AIMING:
		var p_name = "Your Turn" if turn_manager == Player.HUMAN else "AI Turn"
		if game_mode == Player.HUMAN:
			p_name = "Player 1" if turn_manager == Player.HUMAN else "Player 2"
		update_status(p_name)

# --------------------------------------------------------------------------
#   CAMERA SHAKE
# --------------------------------------------------------------------------
func _setup_camera():
	camera = Camera2D.new()
	camera.position = Vector2(TABLE_W/2, TABLE_H/2)
	add_child(camera)

func apply_shake(intensity: float):
	shake_strength = clamp(intensity * 0.015, 0.0, 20.0)

func _process_camera_shake(delta):
	if shake_strength > 0:
		shake_strength = lerp(shake_strength, 0.0, 10.0 * delta)
		var offset = Vector2(randf_range(-1, 1), randf_range(-1, 1)) * shake_strength
		camera.offset = offset
	else:
		camera.offset = Vector2.ZERO

# --------------------------------------------------------------------------
#   INPUT & CONTROLS
# --------------------------------------------------------------------------
func _handle_human_aiming():
	if not is_instance_valid(cue_ball): return
	
	ghost_ball_pos = Vector2.INF
	ghost_target_path = Vector2.ZERO
	
	if is_dragging and aim_vector.length() > 10.0:
		var space = get_world_2d().direct_space_state
		var dir = aim_vector.normalized()
		var start = cue_ball.position
		var end = start + dir * 2000.0
		
		# Sphere Trace instead of Ray Trace for better accuracy
		var query = PhysicsShapeQueryParameters2D.new()
		var shape = CircleShape2D.new()
		shape.radius = BALL_R * 0.9 # Slightly smaller to avoid self-collision issues
		query.shape = shape
		query.transform = Transform2D(0, start)
		query.motion = (end - start)
		query.exclude = [cue_ball.get_rid()]
		
		var result = space.intersect_shape(query, 1) # Get first hit
		
		if not result.is_empty():
			# Logic for SphereCast is different. We approximate hit point.
			# Revert to RayCast for the visual line interaction point to be simple
			var ray_q = PhysicsRayQueryParameters2D.create(start, end)
			ray_q.exclude = [cue_ball.get_rid()]
			var ray_res = space.intersect_ray(ray_q)
			
			if not ray_res.is_empty():
				var collider = ray_res.collider
				if collider is PoolBall:
					ghost_ball_pos = collider.position + (ray_res.normal * (BALL_R * 2.0))
					ghost_target_path = -ray_res.normal * 150.0

func _handle_cue_placement():
	if not is_instance_valid(cue_ball): return
	cue_ball.linear_velocity = Vector2.ZERO
	cue_ball.position = get_global_mouse_position()
	
	var margin = BALL_R + RAIL_WIDTH
	cue_ball.position.x = clamp(cue_ball.position.x, margin, TABLE_W - margin)
	cue_ball.position.y = clamp(cue_ball.position.y, margin, TABLE_H - margin)
	
	# Kitchen rule (behind headstring) is standard, but ignoring for arcade fun
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_set_state(State.AIMING)
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
	if vector.length() < 10.0: return 
	
	var power_ratio = vector.length() / MAX_DRAG_DIST
	var impulse = vector.normalized() * (power_ratio * MAX_POWER)
	
	# Call launch on the ball to handle physics activation properly
	cue_ball.launch(impulse)
	
	play_clack_sound(MAX_POWER * power_ratio * 0.6)
	apply_shake(MAX_POWER * power_ratio)
	
	balls_potted_this_turn.clear()
	foul_committed = false
	foul_reason = ""
	
	_set_state(State.WAITING_FOR_STOP)
	update_status("Balls Rolling...")

# --------------------------------------------------------------------------
#   AI LOGIC
# --------------------------------------------------------------------------
func _run_ai_turn():
	if not is_instance_valid(cue_ball): return
	_set_state(State.SHOOTING)
	update_status("AI is thinking...")
	
	await get_tree().create_timer(1.0).timeout
	
	var targets = []
	for b in balls_on_table:
		if b == cue_ball: continue
		if _is_ball_legal_target(b): targets.append(b)
	
	# Fallback if no legal targets (or only 8 ball left but blocked)
	if targets.is_empty(): 
		for b in balls_on_table: if b != cue_ball: targets.append(b)
	
	var best_shot = Vector2.ZERO
	var best_score = -99999.0
	
	for target in targets:
		for pocket in pockets:
			# 1. Can Target reach Pocket?
			if not _shapecast_clear(target.position, pocket.position, [target, cue_ball]): continue
			
			var to_pocket = pocket.position - target.position
			var aim_dir = to_pocket.normalized()
			var ghost_pos = target.position - (aim_dir * (BALL_R * 2.0))
			
			# 2. Can Cue reach Ghost Position?
			if not _shapecast_clear(cue_ball.position, ghost_pos, [cue_ball, target]): continue
			
			var shot_vec = ghost_pos - cue_ball.position
			
			# Score Calculation
			# Distance penalty
			var score = -shot_vec.length() 
			# Angle penalty (cut shots are harder)
			var cut_angle = abs(shot_vec.angle_to(aim_dir))
			score -= cut_angle * 1000.0
			
			if score > best_score:
				best_score = score
				best_shot = shot_vec
	
	if best_shot == Vector2.ZERO:
		# Just hit something hard
		best_shot = Vector2(randf()-0.5, randf()-0.5).normalized() * 100.0
	else:
		# Add AI Noise
		best_shot = best_shot.rotated(randf_range(-0.02, 0.02))
		var pwr = best_shot.length() + 300.0
		best_shot = best_shot.normalized() * min(pwr, MAX_DRAG_DIST)
	
	_execute_shot(best_shot)

func _shapecast_clear(from: Vector2, to: Vector2, exclude: Array) -> bool:
	var space = get_world_2d().direct_space_state
	var query = PhysicsShapeQueryParameters2D.new()
	var shape = CircleShape2D.new()
	shape.radius = BALL_R # Full width check
	query.shape = shape
	query.transform = Transform2D(0, from)
	query.motion = to - from
	
	var ex_rids = []
	for x in exclude: if is_instance_valid(x): ex_rids.append(x.get_rid())
	query.exclude = ex_rids
	
	var result = space.intersect_shape(query)
	return result.is_empty()

func _is_ball_legal_target(ball):
	var my_group = ai_group if turn_manager == Player.AI else player_group
	
	if my_group == 0: 
		return ball.ball_type != PoolBall.BallType.EIGHT
	
	var target_type = PoolBall.BallType.SOLID if my_group == 1 else PoolBall.BallType.STRIPE
	
	var has_legal_balls = false
	for b in balls_on_table:
		if b.ball_type == target_type: has_legal_balls = true
	
	if has_legal_balls:
		return ball.ball_type == target_type
	else:
		return ball.ball_type == PoolBall.BallType.EIGHT

# --------------------------------------------------------------------------
#   RULES ENGINE
# --------------------------------------------------------------------------
func _on_ball_collision(intensity, pos):
	play_clack_sound(intensity)
	if intensity > 400:
		spawn_particles(intensity, pos)
		apply_shake(intensity * 0.5)

func _on_pocket_ball(ball):
	play_clack_sound(600.0)
	apply_shake(200.0)
	
	if ball == cue_ball:
		foul_committed = true
		foul_reason = "Scratch!"
	else:
		balls_potted_this_turn.append(ball)
		balls_on_table.erase(ball)
		ball.queue_free()

func _end_turn_logic():
	# 1. Check Win/Loss (8 Ball)
	var potted_eight = false
	for b in balls_potted_this_turn:
		if is_instance_valid(b) and b.ball_type == PoolBall.BallType.EIGHT: potted_eight = true
	
	if potted_eight:
		if foul_committed: 
			_game_over("LOSS! Scratched on 8-Ball.")
		else:
			# Check if cleared group
			var my_grp = player_group if turn_manager == Player.HUMAN else ai_group
			var remaining_mine = false
			var target_type = PoolBall.BallType.SOLID if my_grp == 1 else PoolBall.BallType.STRIPE
			if my_grp != 0:
				for b in balls_on_table:
					if b.ball_type == target_type: remaining_mine = true
			
			if remaining_mine:
				_game_over("LOSS! 8-Ball Early.")
			else:
				_game_over("WINNER!")
		return

	# 2. Check Cue Ball Validity
	if not is_instance_valid(cue_ball): 
		foul_committed = true # Redundant check, but safe
		foul_reason = "Scratch"
	else:
		# Check First Contact Rule
		var first_hit = cue_ball.first_collision_body
		if first_hit == null:
			# Hit nothing
			foul_committed = true
			foul_reason = "Hit Nothing"
		elif first_hit is PoolBall:
			# Check if legal ball
			if not _is_ball_legal_target(first_hit):
				foul_committed = true
				foul_reason = "Wrong Ball First"
	
	# 3. Assign Groups if Open
	if player_group == 0 and not foul_committed and not balls_potted_this_turn.is_empty():
		var first = balls_potted_this_turn[0]
		if is_instance_valid(first) and first.ball_type != PoolBall.BallType.EIGHT:
			var is_solid = (first.ball_type == PoolBall.BallType.SOLID)
			if turn_manager == Player.HUMAN:
				player_group = 1 if is_solid else 2
				ai_group = 2 if is_solid else 1
			else:
				ai_group = 1 if is_solid else 2
				player_group = 2 if is_solid else 1
			_update_group_ui()

	# 4. Turn Continuation Logic
	var continue_turn = false
	if not foul_committed and not balls_potted_this_turn.is_empty():
		var my_grp = player_group if turn_manager == Player.HUMAN else ai_group
		var potted_mine = false
		for b in balls_potted_this_turn:
			if is_instance_valid(b):
				if my_grp == 0: potted_mine = true
				elif my_grp == 1 and b.ball_type == PoolBall.BallType.SOLID: potted_mine = true
				elif my_grp == 2 and b.ball_type == PoolBall.BallType.STRIPE: potted_mine = true
		
		if potted_mine: continue_turn = true
	
	if foul_committed:
		update_status("FOUL: " + foul_reason)
		if not is_instance_valid(cue_ball): _respawn_cue_memory()
		_set_state(State.PLACING_CUE)
		_switch_turn()
	elif continue_turn:
		update_status("Go Again!")
		_set_state(State.AIMING)
	else:
		_switch_turn()
		_set_state(State.AIMING)

func _switch_turn():
	if game_mode == Player.AI:
		turn_manager = Player.AI if turn_manager == Player.HUMAN else Player.HUMAN
	else:
		# PVP: Just flip the visual label, logic stays HUMAN
		turn_manager = Player.HUMAN 
		# In a real PVP, you'd track Player 1 vs Player 2 ID variables here
		# But for this codebase, we just flip the group UI logic visually
		var temp = player_group
		player_group = ai_group
		ai_group = temp
	
	_update_group_ui()
	var p_name = "Your Turn" if turn_manager == Player.HUMAN else "AI Turn"
	update_status(p_name)

func _game_over(msg):
	update_status(msg)
	_set_state(State.GAME_OVER)
	await get_tree().create_timer(4.0).timeout
	_set_state(State.MENU)

# --------------------------------------------------------------------------
#   SETUP & VISUALS
# --------------------------------------------------------------------------
func start_game(mode):
	game_mode = mode
	_clear_table_entities()
	_spawn_walls()
	_spawn_pockets()
	_rack_balls()
	_spawn_cue_ball()
	
	player_group = 0; ai_group = 0
	turn_manager = Player.HUMAN
	
	_set_state(State.AIMING)
	_update_group_ui()

func _clear_table_entities():
	for b in balls_on_table: if is_instance_valid(b): b.queue_free()
	balls_on_table.clear()
	if is_instance_valid(cue_ball): cue_ball.queue_free()
	for c in particle_container.get_children(): c.queue_free()
	# Clean walls too to reset geometry
	if is_instance_valid(walls): walls.queue_free()

func _setup_ui_system():
	ui_layer = CanvasLayer.new()
	add_child(ui_layer)
	
	# --- MAIN MENU ---
	menu_control = Control.new()
	menu_control.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui_layer.add_child(menu_control)
	
	var bg = ColorRect.new()
	bg.color = Color(0.1, 0.1, 0.1, 0.95)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	menu_control.add_child(bg)
	
	var title = Label.new()
	title.text = "PRO POOL 2D"
	title.add_theme_font_size_override("font_size", 64)
	title.set_anchors_preset(Control.PRESET_TOP_WIDE)
	title.position.y = 150
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	menu_control.add_child(title)
	
	var btn_vbox = VBoxContainer.new()
	btn_vbox.set_anchors_preset(Control.PRESET_CENTER)
	btn_vbox.grow_horizontal = Control.GROW_DIRECTION_BOTH
	btn_vbox.grow_vertical = Control.GROW_DIRECTION_BOTH
	btn_vbox.custom_minimum_size = Vector2(200, 200)
	menu_control.add_child(btn_vbox)
	
	var btn_ai = Button.new()
	btn_ai.text = "Play vs AI"
	btn_ai.custom_minimum_size = Vector2(0, 50)
	btn_ai.pressed.connect(func(): start_game(Player.AI))
	btn_vbox.add_child(btn_ai)
	
	var btn_pvp = Button.new()
	btn_pvp.text = "Play PvP (Local)"
	btn_pvp.custom_minimum_size = Vector2(0, 50)
	btn_pvp.pressed.connect(func(): start_game(Player.HUMAN))
	btn_vbox.add_child(btn_pvp)
	
	# --- HUD ---
	hud_control = Control.new()
	hud_control.set_anchors_preset(Control.PRESET_FULL_RECT)
	hud_control.visible = false
	hud_control.mouse_filter = Control.MOUSE_FILTER_IGNORE 
	ui_layer.add_child(hud_control)
	
	var top_bar = ColorRect.new()
	top_bar.color = Color(0, 0, 0, 0.5)
	top_bar.size = Vector2(1280, 60)
	top_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	hud_control.add_child(top_bar)
	
	status_label = Label.new()
	status_label.text = "Ready"
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	status_label.size = Vector2(1280, 60)
	status_label.add_theme_font_size_override("font_size", 28)
	hud_control.add_child(status_label)
	
	group_label = Label.new()
	group_label.text = "Table Open"
	group_label.position = Vector2(20, 15)
	hud_control.add_child(group_label)
	
	var btn_reset = Button.new()
	btn_reset.text = "Menu"
	btn_reset.position = Vector2(1200, 10)
	btn_reset.size = Vector2(70, 40)
	btn_reset.pressed.connect(func(): _set_state(State.MENU))
	hud_control.add_child(btn_reset)

func update_status(text):
	status_label.text = text

func _update_group_ui():
	var txt = "Table: Open"
	if player_group == 1: txt = "You: SOLIDS"
	elif player_group == 2: txt = "You: STRIPES"
	group_label.text = txt

# --------------------------------------------------------------------------
#   DRAWING
# --------------------------------------------------------------------------
func _draw():
	if current_state == State.MENU: return
	
	# Background
	draw_rect(Rect2(-1000, -1000, 3000, 3000), Color(0.12, 0.12, 0.14))
	
	# Table Wood
	draw_rect(Rect2(-RAIL_WIDTH, -RAIL_WIDTH, TABLE_W+RAIL_WIDTH*2, TABLE_H+RAIL_WIDTH*2), COL_WOOD)
	# Inner Dark Trim
	draw_rect(Rect2(-5, -5, TABLE_W+10, TABLE_H+10), COL_WOOD_DARK, false, 10.0)
	# Felt
	draw_rect(Rect2(0,0,TABLE_W, TABLE_H), COL_FELT)
	
	# Markers
	for i in range(1, 4):
		draw_circle(Vector2(TABLE_W * (i/4.0), -RAIL_WIDTH/2), 3, Color.WHITE)
		draw_circle(Vector2(TABLE_W * (i/4.0), TABLE_H + RAIL_WIDTH/2), 3, Color.WHITE)
	
	# Aim Guide
	if current_state == State.AIMING and is_dragging and is_instance_valid(cue_ball):
		var start = cue_ball.position
		var pwr = aim_vector.length() / MAX_DRAG_DIST
		var dir = aim_vector.normalized()
		
		# Line
		var line_end = start + dir * 800
		if ghost_ball_pos != Vector2.INF:
			line_end = ghost_ball_pos
			draw_circle(ghost_ball_pos, BALL_R, Color(1, 1, 1, 0.4))
			draw_line(ghost_ball_pos, ghost_ball_pos + ghost_target_path, Color(1,1,1,0.6), 2.0)
		
		draw_line(start, line_end, Color(1,1,1,0.2), 2.0)
		
		# Cue Stick
		var stick_start = start - dir * (30 + pwr * 80)
		var stick_end = stick_start - dir * 300
		draw_line(stick_start, stick_end, Color(0.9, 0.8, 0.6), 8.0)
		draw_line(stick_start, stick_start - dir * 10, Color.BLUE, 8.0)
		
		# Power Arc
		var color = Color.GREEN.lerp(Color.RED, pwr)
		draw_arc(start, 40, -PI/2, -PI/2 + (pwr * TAU), 32, color, 4.0)

# --------------------------------------------------------------------------
#   AUDIO / PARTICLES
# --------------------------------------------------------------------------
func _setup_audio():
	audio_player = AudioStreamPlayer.new()
	var gen = AudioStreamGenerator.new()
	gen.mix_rate = SAMPLE_HZ; gen.buffer_length = 0.1
	audio_player.stream = gen
	add_child(audio_player)
	audio_player.play()
	audio_playback = audio_player.get_stream_playback()

func play_clack_sound(intensity):
	if not audio_playback: return
	var vol = clamp(intensity / 800.0, 0.1, 1.0)
	var frames = int(SAMPLE_HZ * 0.05)
	if audio_playback.get_frames_available() < frames: return
	var buf = PackedVector2Array()
	buf.resize(frames)
	for i in range(frames):
		var t = float(i)/frames
		var val = (sin(t*50.0)*0.5 + randf_range(-1,1)*0.5) * exp(-10*t) * vol
		buf[i] = Vector2(val, val)
	audio_playback.push_buffer(buf)

func spawn_particles(intensity, pos):
	if intensity < 100: return
	var p = CPUParticles2D.new()
	p.position = pos; p.emitting = true; p.one_shot = true
	p.lifetime = 0.5; p.explosiveness = 1.0; p.amount = 12
	p.spread = 180; p.initial_velocity_min = 20; p.initial_velocity_max = 100
	p.scale_amount_max = 3.0; p.color = Color(0.9, 0.9, 1.0, 0.6)
	particle_container.add_child(p)
	await get_tree().create_timer(1.0).timeout
	p.queue_free()

# --------------------------------------------------------------------------
#   BOILERPLATE SPAWNERS
# --------------------------------------------------------------------------
func _spawn_cue_ball():
	cue_ball = _create_ball(Vector2(TABLE_W * 0.25, TABLE_H * 0.5), PoolBall.BallType.CUE, 0)

func _respawn_cue_memory():
	cue_ball = _create_ball(Vector2(-100,-100), PoolBall.BallType.CUE, 0)
	cue_ball.is_stopped = true

func _create_ball(pos, type, num):
	var b = PoolBall.new()
	b.position = pos
	var col_idx = (num - 1) % 7
	var c = BALL_COLORS[col_idx] if num != 8 else Color.BLACK
	if type == PoolBall.BallType.CUE: c = Color.WHITE
	b.setup(num, type, c)
	var shape = CollisionShape2D.new(); var circ = CircleShape2D.new(); circ.radius = BALL_R
	shape.shape = circ; b.add_child(shape)
	b.collided.connect(_on_ball_collision)
	add_child(b)
	if type != PoolBall.BallType.CUE: balls_on_table.append(b)
	return b

func _spawn_walls():
	walls = StaticBody2D.new()
	var mat = PhysicsMaterial.new(); mat.bounce = 0.6; mat.friction = 0.1
	walls.physics_material_override = mat
	add_child(walls)
	
	# Updated Geometry: Cutout corners for pockets
	var rw = RAIL_WIDTH
	var w = TABLE_W
	var h = TABLE_H
	var c = 25.0 # Corner cutout size
	
	# Top Wall
	var p_top = PackedVector2Array([
		Vector2(-rw, -rw), Vector2(w+rw, -rw), 
		Vector2(w-c, 0), Vector2(w/2 + c, 0), Vector2(w/2, -c), Vector2(w/2 - c, 0), Vector2(c, 0)
	])
	_add_poly(walls, p_top)
	
	# Bottom Wall
	var p_bot = PackedVector2Array([
		Vector2(-rw, h+rw), Vector2(w+rw, h+rw),
		Vector2(w-c, h), Vector2(w/2 + c, h), Vector2(w/2, h+c), Vector2(w/2 - c, h), Vector2(c, h)
	])
	_add_poly(walls, p_bot)
	
	# Left Wall
	var p_left = PackedVector2Array([
		Vector2(-rw, -rw), Vector2(0, c), Vector2(0, h-c), Vector2(-rw, h+rw)
	])
	_add_poly(walls, p_left)
	
	# Right Wall
	var p_right = PackedVector2Array([
		Vector2(w+rw, -rw), Vector2(w, c), Vector2(w, h-c), Vector2(w+rw, h+rw)
	])
	_add_poly(walls, p_right)

func _add_poly(node, points):
	var c = CollisionPolygon2D.new()
	c.polygon = points
	node.add_child(c)

func _spawn_pockets():
	pockets.clear()
	for c in get_children(): if c is Pocket: c.queue_free()
	# Positions slightly adjusted for new wall geometry
	var locs = [Vector2(0,0), Vector2(TABLE_W/2, -8), Vector2(TABLE_W, 0), Vector2(0, TABLE_H), Vector2(TABLE_W/2, TABLE_H+8), Vector2(TABLE_W, TABLE_H)]
	for pos in locs:
		var p = Pocket.new(); p.position = pos; add_child(p); p.configure(POCKET_R)
		p.ball_potted.connect(_on_pocket_ball); pockets.append(p)

func _rack_balls():
	var start_x = TABLE_W * 0.75
	var start_y = TABLE_H * 0.5
	var r = BALL_R
	
	# Logic Fix: Proper 8-ball racking
	var nums = []
	for i in range(1, 16): if i != 8: nums.append(i)
	nums.shuffle()
	
	# Insert 8 at index 4 (center of rack)
	nums.insert(4, 8)
	
	# Optional: Enforce corner types (Solid/Stripe on bottom corners)
	# Bottom corners are index 10 and 14 in a row-by-row fill
	# This simple shuffle is usually "good enough" for casual play
	
	var idx = 0
	for col in range(5):
		for row in range(col + 1):
			var x = start_x + (col * r * 1.732)
			var y = start_y + (row * r * 2.0) - (col * r)
			
			var num = nums[idx]
			var type = PoolBall.BallType.SOLID
			if num > 8: type = PoolBall.BallType.STRIPE
			if num == 8: type = PoolBall.BallType.EIGHT
			
			_create_ball(Vector2(x, y), type, num)
			idx += 1

func _setup_physics_world():
	pass

func _are_balls_stopped() -> bool:
	for b in balls_on_table:
		if is_instance_valid(b) and not b.is_stopped: return false
	if is_instance_valid(cue_ball) and not cue_ball.is_stopped: return false
	return true
