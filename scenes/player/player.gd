extends CharacterBody2D

## ============================================================
## FROG PLAYER CONTROLLER
## Movement + Double Jump + Coyote Time + Jump Buffer
## 3-Hit Combo (Melee + Tongue) + Look Up/Down Camera
## ============================================================

# === MOVEMENT ===
@export var speed: float = 100.0        # walk speed
@export var run_speed: float = 180.0    # run speed
@export var acceleration: float = 900.0
@export var friction: float = 800.0
@export var gravity_up: float = 700.0
@export var gravity_down: float = 900.0
@export var max_fall_speed: float = 400.0

# === JUMP ===
@export var jump_velocity: float = -280.0
@export var double_jump_velocity: float = -240.0
@export var coyote_time: float = 0.1
@export var jump_buffer_time: float = 0.12
@export var jump_cut_multiplier: float = 0.4  # variable jump height

# === CAMERA LOOK ===
@export var camera_look_offset: float = 50.0
@export var camera_look_speed: float = 3.0

# === COMBAT ===
@export var melee_damage: int = 10
@export var finisher_damage: int = 20
@export var tongue_damage: int = 10
@export var combo_window: float = 0.5  # detik untuk input combo berikutnya
@export var attack_cooldown: float = 0.15
@export var max_tongue_length: float = 70.0

# === GRAPPLE & SWING ===
@export var max_rope_length: float = 240.0
@export var min_rope_length: float = 20.0
@export var swing_acceleration: float = 800.0
@export var reel_speed: float = 120.0

# === NODE REFERENCES ===
@onready var sprite: Sprite2D = $Sprite2D
@onready var anim_player: AnimationPlayer = $AnimationPlayer
@onready var hitbox: Area2D = $Hitbox
@onready var hitbox_shape: CollisionShape2D = $Hitbox/HitboxShape
@onready var tongue_hitbox: Area2D = $TongueHitbox
@onready var tongue_shape: CollisionShape2D = $TongueHitbox/TongueShape
@onready var hurtbox: Area2D = $Hurtbox
@onready var coyote_timer: Timer = $CoyoteTimer
@onready var jump_buffer_timer: Timer = $JumpBufferTimer
@onready var combo_timer: Timer = $ComboTimer
@onready var camera: Camera2D = $Camera2D
@onready var hit_particles: CPUParticles2D = $HitParticles
@onready var tongue_rope: Line2D = $TongueRope

# === STATE MACHINE ===
enum State {
	IDLE,
	WALK,
	RUN,
	JUMP,
	FALL,
	GRAPPLE,
	SWING,
	ATTACK_1,
	ATTACK_2,
	ATTACK_3,
	TONGUE_ATTACK,
}

var current_state: State = State.IDLE
var previous_state: State = State.IDLE

# === INTERNAL VARS ===
var can_double_jump: bool = true
var was_on_floor: bool = false
var can_coyote_jump: bool = false
var jump_buffered: bool = false
var facing_right: bool = true

# Grapple status
var is_grappled: bool = false
var grapple_anchor: Vector2 = Vector2.ZERO
var rope_length: float = 0.0

# Swallow & Vomit status
var swallowed_object: Node2D = null
var swallowing_target: Node2D = null
var is_vomiting_tongue: bool = false
var vomit_tongue_progress: float = 0.0
var vomit_direction: Vector2 = Vector2.RIGHT
var has_swallowed_this_attack: bool = false
var tongue_target_pos: Vector2 = Vector2.ZERO

# Combat
var combo_count: int = 0  # 0 = no combo, 1 = hit1, 2 = hit2, 3 = finisher
var can_combo: bool = false
var is_attacking: bool = false
var attack_anim_finished: bool = false
var can_attack: bool = true

# Camera look
var camera_target_offset_y: float = 0.0
var base_camera_offset_y: float = 0.0
var shake_intensity: float = 0.0
var shake_duration: float = 0.0

# Damage tracking (biar satu enemy nggak kena 2x per swing)
var _hit_enemies_this_swing: Array = []

# Debug variables
var _last_printed_state: State = State.IDLE
var _last_printed_vel: Vector2 = Vector2.ZERO


func _ready() -> void:
	# Setup timers
	coyote_timer.wait_time = coyote_time
	coyote_timer.one_shot = true
	jump_buffer_timer.wait_time = jump_buffer_time
	jump_buffer_timer.one_shot = true
	combo_timer.wait_time = combo_window
	combo_timer.one_shot = true
	
	# Disable hitboxes by default
	hitbox_shape.disabled = true
	tongue_shape.disabled = true
	
	# Connect signals
	hitbox.area_entered.connect(_on_hitbox_area_entered)
	tongue_hitbox.area_entered.connect(_on_tongue_area_entered)
	hurtbox.area_entered.connect(_on_hurtbox_area_entered)
	combo_timer.timeout.connect(_on_combo_timer_timeout)
	anim_player.animation_finished.connect(_on_animation_finished)


func _physics_process(delta: float) -> void:
	# --- Grapple Firing Input ---
	_handle_grapple_input()
	
	# --- Gravity ---
	_apply_gravity(delta)
	
	# --- Coyote Time ---
	_handle_coyote_time()
	
	# --- Input ---
	var input_dir := Input.get_axis("move_left", "move_right")
	if abs(input_dir) < 0.2:
		input_dir = 0.0
	
	# --- Jump ---
	if is_grappled:
		if Input.is_action_just_pressed("jump"):
			_release_grapple(true) # Jump out of swing!
	else:
		_handle_jump()
	
	# --- Movement (disabled saat attack / grapple) ---
	if is_grappled:
		_handle_swing_physics(input_dir, delta)
	elif not is_attacking:
		_handle_movement(input_dir, delta)
	else:
		# Saat attack, apply friction supaya pelan-pelan berhenti
		velocity.x = move_toward(velocity.x, 0, friction * delta)
	
	# --- Attack ---
	_handle_attack()
	
	# --- Camera Look (W/S) ---
	if not is_grappled:
		_handle_camera_look(delta)
	else:
		# smooth center camera when grappled
		base_camera_offset_y = lerp(base_camera_offset_y, 0.0, camera_look_speed * delta)
	
	# --- Camera Shake ---
	_apply_camera_shake(delta)
	
	# --- Apply movement ---
	was_on_floor = is_on_floor()
	move_and_slide()
	
	# --- Reset double jump saat landing ---
	if is_on_floor() and not was_on_floor:
		can_double_jump = true
		if is_grappled:
			_release_grapple(false)
		# Check jump buffer
		if jump_buffered:
			_perform_jump()
			jump_buffered = false
	
	# --- Update state & animation ---
	_update_state(input_dir)
	_update_animation()
	
	# --- Flip sprite ---
	_update_facing(input_dir)
	
	# --- Belly Bulge Scale Override ---
	_apply_bulge_scale()
	
	# --- Render Tongue for Swallow / Vomit / Grapple ---
	var mouth_pos = get_mouth_local_position()
	if swallowing_target != null and is_instance_valid(swallowing_target) and has_swallowed_this_attack:
		tongue_rope.points = PackedVector2Array([
			mouth_pos,
			to_local(swallowing_target.global_position)
		])
		tongue_rope.visible = true
	elif is_vomiting_tongue:
		vomit_tongue_progress += delta
		var max_len = max_tongue_length
		var extension_time = 0.08
		var retraction_time = 0.08
		var total_time = extension_time + retraction_time
		
		# Lock mouth origin using vomit direction vector to prevent mouth shift if player flips mid-vomit
		var vomit_mouth_x = 4.0 if vomit_direction.x > 0 else -4.0
		var vomit_mouth_pos = Vector2(vomit_mouth_x, -18.0)
		
		if vomit_tongue_progress <= extension_time:
			var t = vomit_tongue_progress / extension_time
			var ext_point = vomit_mouth_pos + vomit_direction * max_len * t
			tongue_rope.points = PackedVector2Array([vomit_mouth_pos, ext_point])
			tongue_rope.visible = true
			if is_instance_valid(swallowed_object):
				swallowed_object.visible = true
				swallowed_object.global_position = to_global(ext_point)
				swallowed_object.scale = Vector2(0.5, 0.5)
		elif vomit_tongue_progress <= total_time:
			if swallowed_object != null:
				var peak_pos = to_global(vomit_mouth_pos + vomit_direction * max_len)
				var proj_scene = load("res://scenes/player/spit_projectile.tscn")
				var proj = proj_scene.instantiate()
				proj.global_position = peak_pos
				proj.direction = vomit_direction
				proj.parent_player = self
				proj.swallowed_object = swallowed_object
				get_parent().add_child(proj)
				
				# Hide and disable it again for the projectile to own
				swallowed_object.visible = false
				swallowed_object.process_mode = Node.PROCESS_MODE_DISABLED
				
				# Clear reference and apply recoil
				swallowed_object = null
				velocity += -vomit_direction * 120.0
				shake_camera(2.5, 0.1)
				
			var t = (vomit_tongue_progress - extension_time) / retraction_time
			var ext_point = vomit_mouth_pos + vomit_direction * max_len * (1.0 - t)
			tongue_rope.points = PackedVector2Array([vomit_mouth_pos, ext_point])
			tongue_rope.visible = true
		else:
			is_vomiting_tongue = false
			tongue_rope.visible = false
	elif is_attacking and combo_count == 3 and not has_swallowed_this_attack:
		# Update target position to track the target in real time
		if swallowing_target != null and is_instance_valid(swallowing_target):
			tongue_target_pos = to_local(swallowing_target.global_position)
			
		var anim_pos = anim_player.current_animation_position
		var ext_point = Vector2.ZERO
		
		# If swallow is triggered at peak (anim_pos >= 0.2)
		if anim_pos >= 0.2 and swallowing_target != null and not has_swallowed_this_attack:
			_swallow_target(swallowing_target, null)
			
		if anim_pos < 0.2:
			var t = anim_pos / 0.2
			ext_point = mouth_pos + (tongue_target_pos - mouth_pos) * t
		elif anim_pos < 0.35:
			ext_point = tongue_target_pos
		else:
			var t = (0.5 - anim_pos) / 0.15
			ext_point = mouth_pos + (tongue_target_pos - mouth_pos) * max(0.0, t)
			
		tongue_rope.points = PackedVector2Array([mouth_pos, ext_point])
		tongue_rope.visible = true
	elif is_grappled:
		pass
	else:
		tongue_rope.visible = false
	
	# Request redraw to update tongue tip visual position
	queue_redraw()
	
	# --- Debug Print ---
	if current_state != _last_printed_state or velocity.round() != _last_printed_vel.round():
		_last_printed_state = current_state
		_last_printed_vel = velocity
		print("[DEBUG] State: ", State.keys()[current_state], " | Vel: ", velocity, " | OnFloor: ", is_on_floor(), " | InputDir: ", input_dir)


# =============================================================
# GRAVITY
# =============================================================
func _apply_gravity(delta: float) -> void:
	if not is_on_floor():
		var grav = gravity_up if velocity.y < 0 else gravity_down
		velocity.y += grav * delta
		velocity.y = min(velocity.y, max_fall_speed)


# =============================================================
# COYOTE TIME
# =============================================================
func _handle_coyote_time() -> void:
	if was_on_floor and not is_on_floor() and velocity.y >= 0:
		can_coyote_jump = true
		coyote_timer.start()
	
	if can_coyote_jump and coyote_timer.is_stopped():
		can_coyote_jump = false


# =============================================================
# JUMP
# =============================================================
func _handle_jump() -> void:
	if Input.is_action_just_pressed("jump"):
		if is_on_floor() or can_coyote_jump:
			_perform_jump()
			can_coyote_jump = false
			coyote_timer.stop()
		elif can_double_jump:
			_perform_double_jump()
		else:
			jump_buffered = true
			jump_buffer_timer.start()
	
	if Input.is_action_just_released("jump") and velocity.y < 0:
		velocity.y *= jump_cut_multiplier
	
	if jump_buffered and jump_buffer_timer.is_stopped():
		jump_buffered = false


func _perform_jump() -> void:
	velocity.y = jump_velocity
	can_double_jump = true
	is_attacking = false
	_reset_combo()


func _perform_double_jump() -> void:
	velocity.y = double_jump_velocity
	can_double_jump = false
	is_attacking = false
	_reset_combo()


# =============================================================
# MOVEMENT
# =============================================================
func _handle_movement(input_dir: float, delta: float) -> void:
	var target_speed = speed
	if Input.is_action_pressed("run") and is_on_floor():
		target_speed = run_speed
		
	if input_dir != 0:
		velocity.x = move_toward(velocity.x, input_dir * target_speed, acceleration * delta)
	else:
		velocity.x = move_toward(velocity.x, 0, friction * delta)


# =============================================================
# GRAPPLE INPUT & SWING PHYSICS
# =============================================================
func _handle_grapple_input() -> void:
	if is_attacking or is_vomiting_tongue:
		return
	if Input.is_action_just_pressed("grapple"):
		if is_grappled:
			_release_grapple(true)
		else:
			_shoot_grapple()
func _shoot_grapple() -> void:
	var mouse_pos = get_global_mouse_position()
	var player_center = global_position + get_mouth_local_position()
	var space_state = get_world_2d().direct_space_state
	var query = PhysicsRayQueryParameters2D.create(player_center, mouse_pos, 1) # Layer 1 is ground
	var result = space_state.intersect_ray(query)
	if result:
		var hit_pos = result.position
		var dist = (hit_pos - player_center).length()
		if dist <= max_rope_length:
			is_grappled = true
			grapple_anchor = hit_pos
			
			# Shorten the rope slightly so the player hangs immediately
			rope_length = max(dist - 20.0, min_rope_length)
			
			# Lift player up immediately
			var to_anchor = grapple_anchor - player_center
			var n = to_anchor.normalized()
			var excess = dist - rope_length
			global_position += n * excess
			
			# Add a tiny upward pop velocity to break floor contact
			velocity.y = -50.0
			
			tongue_rope.visible = true
			print("[GRAPPLE] Hook attached at ", grapple_anchor, " (length: ", rope_length, ")")


func _release_grapple(boost: bool = false) -> void:
	if not is_grappled:
		return
	is_grappled = false
	tongue_rope.visible = false
	print("[GRAPPLE] Released")
	if boost:
		var input_dir = Input.get_axis("move_left", "move_right")
		velocity.y = jump_velocity * 0.8
		if input_dir != 0:
			velocity.x += input_dir * speed * 0.6


func _handle_swing_physics(input_dir: float, delta: float) -> void:
	var player_center = global_position + get_mouth_local_position()
	var to_anchor = grapple_anchor - player_center
	var dist = to_anchor.length()
	
	# Reel up/down
	if Input.is_action_pressed("look_up"):
		rope_length = max(rope_length - reel_speed * delta, min_rope_length)
	elif Input.is_action_pressed("look_down"):
		rope_length = min(rope_length + reel_speed * delta, max_rope_length)
		
	# Constrain position to rope length
	if dist > rope_length:
		var n = to_anchor.normalized()
		var excess = dist - rope_length
		global_position += n * excess
		
		# Cancel velocity component directed away from anchor
		var vel_dot_n = velocity.dot(n)
		if vel_dot_n < 0:
			velocity -= n * vel_dot_n
			
	# Add tangential acceleration
	if input_dir != 0:
		var n = to_anchor.normalized()
		var tangent = Vector2(-n.y, n.x)
		if tangent.x * input_dir < 0:
			tangent = -tangent
		velocity += tangent * swing_acceleration * delta
		
	# Draw the Line2D tongue rope
	tongue_rope.points = PackedVector2Array([
		get_mouth_local_position(),
		to_local(grapple_anchor)
	])


# =============================================================
# ATTACK SYSTEM (3-Hit Combo + Tongue + Spit/Vomit)
# =============================================================
func _handle_attack() -> void:
	if not (Input.is_action_just_pressed("attack") or Input.is_action_just_pressed("tongue_attack")):
		return
		
	# Release grapple immediately if we attack, swallow, or vomit while swinging
	if is_grappled:
		_release_grapple(false)
		
	# Vomit action takes precedence if holding swallowed object
	if swallowed_object != null:
		_vomit_object()
		return
	
	if Input.is_action_just_pressed("attack"):
		if not can_attack:
			return
		
		if can_combo and combo_count < 2:
			combo_count += 1
			can_combo = false
			_start_attack()
		elif not is_attacking:
			combo_count = 1
			_start_attack()
			
	elif Input.is_action_just_pressed("tongue_attack"):
		if not can_attack:
			return
		
		if can_combo or not is_attacking:
			combo_count = 3
			can_combo = false
			_start_attack()


func _start_attack() -> void:
	is_attacking = true
	attack_anim_finished = false
	_hit_enemies_this_swing.clear()
	
	var suffix = "_right" if facing_right else "_left"
	
	match combo_count:
		1:
			_activate_melee_hitbox()
			anim_player.play("attack_1" + suffix)
		2:
			_activate_melee_hitbox()
			anim_player.play("attack_2" + suffix)
		3:
			has_swallowed_this_attack = false
			# Auto-aim closest swallowable target
			var target = _find_closest_swallowable_target()
			if target != null:
				swallowing_target = target
				if target.global_position.x > global_position.x:
					facing_right = true
				else:
					facing_right = false
				sprite.flip_h = not facing_right
				tongue_target_pos = to_local(target.global_position)
			else:
				swallowing_target = null
				var dir_sign = 1.0 if facing_right else -1.0
				var mouth_pos = get_mouth_local_position()
				tongue_target_pos = mouth_pos + Vector2(max_tongue_length * dir_sign, 0.0)
				
			_activate_tongue_hitbox()
			suffix = "_right" if facing_right else "_left"
			anim_player.play("attack_3" + suffix)
		_:
			_reset_combo()


func _activate_melee_hitbox() -> void:
	hitbox_shape.disabled = false
	tongue_shape.disabled = true


func _activate_tongue_hitbox() -> void:
	tongue_shape.disabled = false
	hitbox_shape.disabled = true


func _deactivate_all_hitboxes() -> void:
	hitbox_shape.disabled = true
	tongue_shape.disabled = true


func _reset_combo() -> void:
	combo_count = 0
	can_combo = false
	is_attacking = false
	_deactivate_all_hitboxes()
	_hit_enemies_this_swing.clear()


func _get_current_damage() -> int:
	match combo_count:
		1: return melee_damage      # 10
		2: return melee_damage      # 10
		3: return finisher_damage   # 20
		_: return melee_damage


# =============================================================
# SWALLOW & VOMIT MECHANICS
# =============================================================
func _swallow_target(body: Node2D, _area: Area2D) -> void:
	print("[COMBAT] Swallowed target: ", body.name)
	swallowed_object = body
	swallowing_target = body
	has_swallowed_this_attack = true
	
	# Disable the target's collision shapes and hurtboxes
	if body.has_node("DummyHurtbox/DummyHurtboxShape"):
		body.get_node("DummyHurtbox/DummyHurtboxShape").set_deferred("disabled", true)
	elif body.has_node("Hurtbox/HurtboxShape"):
		body.get_node("Hurtbox/HurtboxShape").set_deferred("disabled", true)
	if body.has_node("CollisionShape2D"):
		body.get_node("CollisionShape2D").set_deferred("disabled", true)
		
	# Play pull effect (animate target to player)
	var tween = create_tween().set_parallel(true)
	var target_pos = global_position + get_mouth_local_position()
	tween.tween_property(body, "global_position", target_pos, 0.15)
	tween.tween_property(body, "scale", Vector2.ZERO, 0.15)
	
	# Shake camera for juice feedback
	shake_camera(3.0, 0.1)
	
	await tween.finished
	
	swallowing_target = null
	# Set invisible and disable processing
	body.visible = false
	body.process_mode = Node.PROCESS_MODE_DISABLED


func _vomit_object() -> void:
	if swallowed_object == null:
		return
		
	print("[COMBAT] Initiating aimed tongue vomit sequence!")
	is_vomiting_tongue = true
	vomit_tongue_progress = 0.0
	
	# Aim vomit directly towards the mouse position
	var mouth_global_pos = global_position + get_mouth_local_position()
	var mouse_pos = get_global_mouse_position()
	vomit_direction = (mouse_pos - mouth_global_pos).normalized()
	
	# Fallback if mouse is exactly on player mouth
	if vomit_direction.length() == 0:
		vomit_direction = Vector2.RIGHT if facing_right else Vector2.LEFT
		
	# Automatically flip player sprite to face the vomit target direction
	if vomit_direction.x > 0:
		facing_right = true
	elif vomit_direction.x < 0:
		facing_right = false
	sprite.flip_h = not facing_right
	
	# Juice feedback
	shake_camera(1.5, 0.05)


func _apply_bulge_scale() -> void:
	if swallowed_object != null:
		# Belly bulge scale (1.15x normal scale of 0.65)
		sprite.scale = Vector2(0.75, 0.75)


# =============================================================
# HITBOX SIGNALS
# =============================================================
func _on_hitbox_area_entered(area: Area2D) -> void:
	_deal_damage_to(area)


func _on_tongue_area_entered(area: Area2D) -> void:
	var body = area.get_parent()
	if body == self:
		return
		
	# Try to swallow first if empty belly and it's a valid swallowable target
	if swallowed_object == null:
		if body.has_method("take_damage") and body.name != "Player":
			_swallow_target(body, area)
			return # swallowed! skip regular damage dealing
			
	_deal_damage_to(area)


func _deal_damage_to(area: Area2D) -> void:
	var body = area.get_parent()
	if body == self:
		return
	if body in _hit_enemies_this_swing:
		return
	
	_hit_enemies_this_swing.append(body)
	
	var damage = _get_current_damage()
	
	if body.has_method("take_damage"):
		body.take_damage(damage)
		print("[COMBAT] Hit ", body.name, " for ", damage, " damage! (combo ", combo_count, ")")
		
		# === JUICY COMBAT FEEDBACK ===
		hit_particles.global_position = area.global_position
		if combo_count == 3:
			hit_particles.color = Color(1.0, 0.35, 0.45) # pink tongue splat
			shake_camera(4.0, 0.15)
			trigger_hit_stop(0.08)
		else:
			hit_particles.color = Color(1.0, 0.9, 0.4) # yellow spark
			shake_camera(1.5, 0.08)
			trigger_hit_stop(0.04)
		hit_particles.restart()
	else:
		print("[COMBAT] Hit ", body.name, " but no take_damage() method found!")


# =============================================================
# HURTBOX — Player damage from enemy
# =============================================================
func _on_hurtbox_area_entered(area: Area2D) -> void:
	var attacker = area.get_parent()
	if attacker.has_method("get_attack_damage"):
		var dmg = attacker.get_attack_damage()
		take_damage(dmg)
	else:
		print("[PLAYER] Got hit by ", attacker.name, " but no get_attack_damage() method!")


func take_damage(amount: int) -> void:
	print("[PLAYER] Took ", amount, " damage!")
	sprite.modulate = Color.RED
	await get_tree().create_timer(0.1).timeout
	sprite.modulate = Color(1, 1, 1, 1)


# =============================================================
# CAMERA LOOK & SHAKE
# =============================================================
func _handle_camera_look(delta: float) -> void:
	if Input.is_action_pressed("look_up"):
		camera_target_offset_y = -camera_look_offset
	elif Input.is_action_pressed("look_down"):
		camera_target_offset_y = camera_look_offset
	else:
		camera_target_offset_y = 0.0
	
	base_camera_offset_y = lerp(base_camera_offset_y, camera_target_offset_y, camera_look_speed * delta)


func _apply_camera_shake(delta: float) -> void:
	var shake_offset := Vector2.ZERO
	if shake_duration > 0.0:
		shake_duration -= delta
		shake_offset = Vector2(
			randf_range(-shake_intensity, shake_intensity),
			randf_range(-shake_intensity, shake_intensity)
		)
	camera.offset = Vector2(0, base_camera_offset_y) + shake_offset


func shake_camera(intensity: float, duration: float) -> void:
	shake_intensity = intensity
	shake_duration = duration


func trigger_hit_stop(duration: float) -> void:
	Engine.time_scale = 0.05
	await get_tree().create_timer(duration, true, false, true).timeout
	Engine.time_scale = 1.0


# =============================================================
# STATE MACHINE & ANIMATION
# =============================================================
func _update_state(input_dir: float) -> void:
	previous_state = current_state
	
	if is_attacking:
		match combo_count:
			1: current_state = State.ATTACK_1
			2: current_state = State.ATTACK_2
			3: current_state = State.ATTACK_3
		return
		
	if is_grappled:
		current_state = State.SWING
		return
	
	if not is_on_floor():
		if velocity.y < 0:
			current_state = State.JUMP
		else:
			current_state = State.FALL
	elif abs(input_dir) > 0.1:
		if Input.is_action_pressed("run"):
			current_state = State.RUN
		else:
			current_state = State.WALK
	else:
		current_state = State.IDLE


func _update_animation() -> void:
	if is_attacking:
		return
	
	var anim_base: String
	var speed_scale: float = 1.0
	
	match current_state:
		State.IDLE:
			anim_base = "idle"
		State.WALK:
			anim_base = "run"      # reuse walk cycle
			speed_scale = 0.8       # play slower
		State.RUN:
			anim_base = "run"      # reuse walk cycle
			speed_scale = 1.5       # play faster
		State.JUMP:
			anim_base = "jump"
		State.FALL:
			anim_base = "fall"
		State.SWING, State.GRAPPLE:
			anim_base = "jump"      # swing uses jump pose
		_:
			anim_base = "idle"
			
	anim_player.speed_scale = speed_scale
	
	var suffix = "_right" if facing_right else "_left"
	var anim_name = anim_base + suffix
	
	if anim_player.current_animation != anim_name:
		anim_player.play(anim_name)


func _update_facing(input_dir: float) -> void:
	if is_attacking:
		return
	
	if input_dir > 0:
		facing_right = true
	elif input_dir < 0:
		facing_right = false
		
	# Mirror the sprite texture using flip_h
	sprite.flip_h = not facing_right
	
	# Flip hitbox position
	var hitbox_offset = abs(hitbox.position.x)
	hitbox.position.x = hitbox_offset if facing_right else -hitbox_offset
	
	var tongue_offset = abs(tongue_hitbox.position.x)
	tongue_hitbox.position.x = tongue_offset if facing_right else -tongue_offset


# =============================================================
# ANIMATION CALLBACKS
# =============================================================
func _on_animation_finished(anim_name: StringName) -> void:
	var name_str = str(anim_name)
	if name_str.begins_with("attack_1") or name_str.begins_with("attack_2"):
		_deactivate_all_hitboxes()
		attack_anim_finished = true
		can_combo = true
		combo_timer.start()
		is_attacking = false
	elif name_str.begins_with("attack_3"):
		_deactivate_all_hitboxes()
		_reset_combo()


func _on_combo_timer_timeout() -> void:
	if can_combo:
		_reset_combo()


func _draw() -> void:
	if tongue_rope.visible and tongue_rope.points.size() > 1:
		# Draw the circular tongue tip at the end of the tongue Line2D
		draw_circle(tongue_rope.points[1], 4.5, Color(0.88, 0.33, 0.42, 1))


func get_mouth_local_position() -> Vector2:
	# Sprite height is 48px, scale is 0.65.
	# Frog mouth is roughly at y = -18px locally.
	# Slightly offset horizontally based on facing direction.
	var offset_x = 3.5 if facing_right else -3.5
	return Vector2(offset_x, -18.0)


func _find_closest_swallowable_target() -> Node2D:
	var mouth_global_pos = global_position + get_mouth_local_position()
	var best_target: Node2D = null
	var best_dist: float = max_tongue_length # search radius
	
	var space_state = get_world_2d().direct_space_state
	var query = PhysicsShapeQueryParameters2D.new()
	
	var circle = CircleShape2D.new()
	circle.radius = max_tongue_length
	query.shape = circle
	query.transform = Transform2D(0.0, mouth_global_pos)
	query.collision_mask = 20 # layer 3 (Enemy) and layer 5 (EnemyHurtbox)
	query.collide_with_areas = true
	query.collide_with_bodies = true
	
	var results = space_state.intersect_shape(query)
	for result in results:
		var collider = result.collider
		if collider == self:
			continue
			
		var target_node = collider
		if collider is Area2D:
			target_node = collider.get_parent()
			
		if target_node == self:
			continue
			
		if target_node.has_method("take_damage") and target_node.name != "Player":
			var dist = (target_node.global_position - mouth_global_pos).length()
			if dist < best_dist:
				best_dist = dist
				best_target = target_node
				
	return best_target
