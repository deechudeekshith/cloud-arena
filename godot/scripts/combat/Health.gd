class_name Health
extends Node

## Reusable HP pool: damage / heal / death / respawn hooks.
## Gameplay-only; no rendering or networking inside.

signal damaged(amount: float, from_id: int, headshot: bool)
signal died(killer_id: int)
signal respawned
signal changed(hp: float, max_hp: float)

@export var max_hp := 100.0
var hp := 100.0
var alive := true
var last_hit_time := -99.0
# Auto-regen (player health): heals regen_rate HP/sec once regen_delay
# seconds have passed since the last hit. 0 rate = off (bots, default).
var regen_rate := 0.0
var regen_delay := 5.0

func _ready() -> void:
	hp = max_hp

func _process(dt: float) -> void:
	if not alive or regen_rate <= 0.0 or hp >= max_hp:
		return
	if Time.get_ticks_msec() / 1000.0 - last_hit_time < regen_delay:
		return
	heal(regen_rate * dt)

func reset_full() -> void:
	hp = max_hp
	alive = true
	changed.emit(hp, max_hp)
	respawned.emit()

func take_damage(amount: float, from_id: int = -1, headshot: bool = false) -> void:
	if not alive:
		return
	hp = maxf(0.0, hp - amount)
	last_hit_time = Time.get_ticks_msec() / 1000.0
	damaged.emit(amount, from_id, headshot)
	changed.emit(hp, max_hp)
	if hp <= 0.0:
		alive = false
		died.emit(from_id)

func heal(amount: float) -> void:
	if not alive:
		return
	hp = minf(max_hp, hp + amount)
	changed.emit(hp, max_hp)
