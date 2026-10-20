class_name AvatarDB
extends RefCounted

## 4 original low-poly avatar presets. They share one skeleton /
## animation interface (see HumanoidBuilder + AnimController) and differ
## only in proportions / colors / accessories. Lightweight: flat colors,
## shared materials, no textures.

const PRESETS := [
	{
		"id": 0, "name": "Scout",
		"jacket": Color(0.16, 0.35, 0.55), "pants": Color(0.13, 0.15, 0.2),
		"skin": Color(0.85, 0.62, 0.47), "vest": Color(0.1, 0.12, 0.16),
		"boots": Color(0.08, 0.08, 0.1), "accent": Color(0.3, 0.85, 1.0),
		"height": 1.78, "bulk": 0.9, "accessory": "visor",
		"ability": "dash", "ability_desc": "SHIFT in air: dash forward 8m (12s cd)",
		"speed_mod": 1.15, "health_mod": 0.9,
	},
	{
		"id": 1, "name": "Trooper",
		"jacket": Color(0.35, 0.42, 0.25), "pants": Color(0.2, 0.2, 0.15),
		"skin": Color(0.55, 0.38, 0.27), "vest": Color(0.25, 0.22, 0.15),
		"boots": Color(0.12, 0.1, 0.08), "accent": Color(1.0, 0.7, 0.2),
		"height": 1.84, "bulk": 1.1, "accessory": "helmet",
		"ability": "overshield", "ability_desc": "C: +50 overshield for 6s (18s cd)",
		"speed_mod": 0.9, "health_mod": 1.25,
	},
	{
		"id": 2, "name": "Medic",
		"jacket": Color(0.75, 0.78, 0.8), "pants": Color(0.3, 0.35, 0.45),
		"skin": Color(0.92, 0.72, 0.58), "vest": Color(0.8, 0.15, 0.2),
		"boots": Color(0.15, 0.15, 0.18), "accent": Color(1.0, 0.25, 0.3),
		"height": 1.72, "bulk": 0.95, "accessory": "backpack",
		"ability": "regen_field", "ability_desc": "R: deploy heal beacon 15 HP/s, 4m radius, 8s (20s cd)",
		"speed_mod": 1.0, "health_mod": 1.0,
	},
	{
		"id": 3, "name": "Ghost",
		"jacket": Color(0.12, 0.13, 0.16), "pants": Color(0.1, 0.1, 0.13),
		"skin": Color(0.7, 0.5, 0.38), "vest": Color(0.18, 0.18, 0.22),
		"boots": Color(0.05, 0.05, 0.06), "accent": Color(0.5, 1.0, 0.6),
		"height": 1.8, "bulk": 1.0, "accessory": "hood",
		"ability": "cloak", "ability_desc": "C: 4s invisibility + silent footsteps (22s cd)",
		"speed_mod": 1.1, "health_mod": 0.85,
	},
]

static func count() -> int:
	return PRESETS.size()

static func get_preset(idx: int) -> Dictionary:
	return PRESETS[clamp(idx, 0, PRESETS.size() - 1)]

static func names() -> PackedStringArray:
	var out := PackedStringArray()
	for p in PRESETS:
		out.append(str(p["name"]))
	return out
