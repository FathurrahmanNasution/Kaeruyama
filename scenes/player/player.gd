extends CharacterBody2D

## ============================================================
## FROG PLAYER CONTROLLER
## Movement + Double Jump + Coyote Time + Jump Buffer
## 3-Hit Combo (Melee + Tongue) + Look Up/Down Camera
## ============================================================

# === MOVEMENT ===
@export var speed: float = 120.0
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

# === STATE MACHINE ===
enum State {
	IDLE,
	RUN,
	JUMP,
	FALL,
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
	# --- Gravity ---
	_apply_gravity(delta)
	
	# --- Coyote Time ---
	_handle_coyote_time()
	
	# --- Input ---
	var input_dir := Input.get_axis("move_left", "move_right")
	if abs(input_dir) < 0.2:
		input_dir = 0.0
	
	# --- Jump (harus sebelum movement supaya langsung apply) ---
	_handle_jump()
	
	# --- Movement (disabled saat attack) ---
	if not is_attacking:
		_handle_movement(input_dir, delta)
	else:
		# Saat attack, apply friction supaya pelan-pelan berhenti
		velocity.x = move_toward(velocity.x, 0, friction * delta)
	
	# --- Attack ---
	_handle_attack()
	
	# --- Camera Look (W/S) ---
	_handle_camera_look(delta)
	
	# --- Camera Shake ---
	_apply_camera_shake(delta)
	
	# --- Apply movement ---
	was_on_floor = is_on_floor()
	move_and_slide()
	
	# --- Reset double jump saat landing ---
	if is_on_floor() and not was_on_floor:
		can_double_jump = true
		# Check jump buffer
		if jump_buffered:
			_perform_jump()
			jump_buffered = false
	
	# --- Update state & animation ---
	_update_state(input_dir)
	_update_animation()
	
	# --- Flip sprite ---
	_update_facing(input_dir)
	
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
	# Kalau tadi di lantai, sekarang nggak → mulai coyote timer
	if was_on_floor and not is_on_floor() and velocity.y >= 0:
		can_coyote_jump = true
		coyote_timer.start()
	
	# Kalau coyote timer habis
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
			# Buffer jump kalau belum landing
			jump_buffered = true
			jump_buffer_timer.start()
	
	# Variable jump height: lepas tombol → potong velocity
	if Input.is_action_just_released("jump") and velocity.y < 0:
		velocity.y *= jump_cut_multiplier
	
	# Clear jump buffer kalau timer habis
	if jump_buffered and jump_buffer_timer.is_stopped():
		jump_buffered = false


func _perform_jump() -> void:
	velocity.y = jump_velocity
	can_double_jump = true
	is_attacking = false  # Cancel attack saat jump
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
	if input_dir != 0:
		velocity.x = move_toward(velocity.x, input_dir * speed, acceleration * delta)
	else:
		velocity.x = move_toward(velocity.x, 0, friction * delta)


# =============================================================
# ATTACK SYSTEM (3-Hit Combo + Tongue)
# =============================================================
func _handle_attack() -> void:
	if not (Input.is_action_just_pressed("attack") or Input.is_action_just_pressed("tongue_attack")):
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
			# Finisher — pakai tongue attack (range lebih jauh)
			_activate_tongue_hitbox()
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
		3: return finisher_damage   # 20 (2x lipat)
		_: return melee_damage


# =============================================================
# HITBOX SIGNALS
# =============================================================
func _on_hitbox_area_entered(area: Area2D) -> void:
	_deal_damage_to(area)


func _on_tongue_area_entered(area: Area2D) -> void:
	_deal_damage_to(area)


func _deal_damage_to(area: Area2D) -> void:
	var body = area.get_parent()
	if body == self:
		return
	if body in _hit_enemies_this_swing:
		return
	
	_hit_enemies_this_swing.append(body)
	
	var damage = _get_current_damage()
	
	# Panggil take_damage() di enemy (koordinasi sama Hilmy)
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
# HURTBOX — Player kena damage dari enemy
# =============================================================
func _on_hurtbox_area_entered(area: Area2D) -> void:
	# Nanti Hilmy bikin enemy attack Area2D yang masuk ke sini
	var attacker = area.get_parent()
	if attacker.has_method("get_attack_damage"):
		var dmg = attacker.get_attack_damage()
		take_damage(dmg)
	else:
		print("[PLAYER] Got hit by ", attacker.name, " but no get_attack_damage() method!")


func take_damage(amount: int) -> void:
	# TODO: implement HP system nanti
	print("[PLAYER] Took ", amount, " damage!")
	# Flash effect placeholder
	sprite.modulate = Color.RED
	await get_tree().create_timer(0.1).timeout
	sprite.modulate = Color(1, 1, 1, 1)


# =============================================================
# CAMERA LOOK & JUICY SHAKE
# =============================================================
func _handle_camera_look(delta: float) -> void:
	if Input.is_action_pressed("look_up"):
		camera_target_offset_y = -camera_look_offset
	elif Input.is_action_pressed("look_down"):
		camera_target_offset_y = camera_look_offset
	else:
		camera_target_offset_y = 0.0
	
	# Smooth lerp ke target offset
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
	# ignore_time_scale = true allows running in real-world seconds
	await get_tree().create_timer(duration, true, false, true).timeout
	Engine.time_scale = 1.0


# =============================================================
# STATE MACHINE & ANIMATION
# =============================================================
func _update_state(input_dir: float) -> void:
	previous_state = current_state
	
	# Attack states override everything
	if is_attacking:
		match combo_count:
			1: current_state = State.ATTACK_1
			2: current_state = State.ATTACK_2
			3: current_state = State.ATTACK_3
		return
	
	if not is_on_floor():
		if velocity.y < 0:
			current_state = State.JUMP
		else:
			current_state = State.FALL
	elif abs(input_dir) > 0.1:
		current_state = State.RUN
	else:
		current_state = State.IDLE


func _update_animation() -> void:
	# Jangan interrupt attack animation
	if is_attacking:
		return
	
	var anim_base: String
	match current_state:
		State.IDLE:
			anim_base = "idle"
		State.RUN:
			anim_base = "run"
		State.JUMP:
			anim_base = "jump"
		State.FALL:
			anim_base = "fall"
		_:
			anim_base = "idle"
	
	var suffix = "_right" if facing_right else "_left"
	var anim_name = anim_base + suffix
	
	if anim_player.current_animation != anim_name:
		anim_player.play(anim_name)


func _update_facing(input_dir: float) -> void:
	if is_attacking:
		return  # Jangan flip saat attack
	
	if input_dir > 0:
		facing_right = true
	elif input_dir < 0:
		facing_right = false
	
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
		# Finisher selesai → full reset
		_deactivate_all_hitboxes()
		_reset_combo()


func _on_combo_timer_timeout() -> void:
	# Combo window habis tanpa input → reset
	if can_combo:
		_reset_combo()
