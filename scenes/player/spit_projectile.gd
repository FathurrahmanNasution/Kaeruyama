extends Area2D

@export var speed: float = 350.0
@export var damage: int = 15
@export var projectile_gravity: float = 500.0 # Pull force downwards

var direction: Vector2 = Vector2.RIGHT
var parent_player = null
var swallowed_object: Node2D = null
var velocity: Vector2 = Vector2.ZERO

@onready var particles: CPUParticles2D = $Particles

func _ready() -> void:
	# Connect signals
	area_entered.connect(_on_area_entered)
	body_entered.connect(_on_body_entered)
	
	# Initialize velocity
	velocity = direction * speed
	rotation = velocity.angle()
	
	# Start trailing particles
	particles.emitting = true
	
	# Despawn after 3 seconds if it doesn't hit anything
	get_tree().create_timer(3.0).timeout.connect(_on_timeout)

func _physics_process(delta: float) -> void:
	# Apply gravity over time
	velocity.y += projectile_gravity * delta
	global_position += velocity * delta
	
	# Rotate projectile to match its flight path
	rotation = velocity.angle()

func _on_timeout() -> void:
	_splat()

func _on_area_entered(area: Area2D) -> void:
	# Hit enemy hurtbox (Layer 16)
	var body = area.get_parent()
	if body == parent_player or body == swallowed_object:
		return
		
	if body.has_method("take_damage"):
		body.take_damage(damage)
		_splat()

func _on_body_entered(body: Node2D) -> void:
	# Hit ground/walls (Layer 1)
	if body == parent_player or body == swallowed_object:
		return
	if body is TileMap or body is StaticBody2D or body.name.contains("Floor") or body.name.contains("Platform") or body.name.contains("Wall"):
		_splat()

func _splat() -> void:
	# Disable collision and hide projectile
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
	$Visual.visible = false
	
	# Release the swallowed object on impact!
	if is_instance_valid(swallowed_object):
		swallowed_object.global_position = global_position
		swallowed_object.visible = true
		swallowed_object.process_mode = Node.PROCESS_MODE_INHERIT
		
		# Re-enable colliders
		if swallowed_object.has_node("CollisionShape2D"):
			swallowed_object.get_node("CollisionShape2D").set_deferred("disabled", false)
		if swallowed_object.has_node("DummyHurtbox/DummyHurtboxShape"):
			swallowed_object.get_node("DummyHurtbox/DummyHurtboxShape").set_deferred("disabled", false)
		elif swallowed_object.has_node("Hurtbox/HurtboxShape"):
			swallowed_object.get_node("Hurtbox/HurtboxShape").set_deferred("disabled", false)
		
		# Animate pop-out scale
		swallowed_object.scale = Vector2.ZERO
		var tween = create_tween()
		tween.tween_property(swallowed_object, "scale", Vector2.ONE, 0.15)
	
	# Play explosion particles
	particles.emitting = false
	var splat_particles = $SplatParticles
	splat_particles.emitting = true
	
	# Free projectile scene after particles finish
	await get_tree().create_timer(0.4).timeout
	queue_free()
