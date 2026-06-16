extends StaticBody2D

## Test Dummy — target latihan buat test combat system
## Punya take_damage() supaya compatible sama hitbox player

var hp: int = 100
var max_hp: int = 100
@onready var visual: ColorRect = $DummyVisual


func take_damage(amount: int) -> void:
	hp -= amount
	print("[DUMMY] Took ", amount, " damage! HP: ", hp, "/", max_hp)
	
	# Flash effect
	_flash_white()
	
	if hp <= 0:
		hp = max_hp  # Reset HP (dummy nggak mati, buat testing)
		print("[DUMMY] HP reset to ", max_hp, "!")


func _flash_white() -> void:
	visual.color = Color.WHITE
	await get_tree().create_timer(0.08).timeout
	visual.color = Color(0.8, 0.2, 0.2, 1)
