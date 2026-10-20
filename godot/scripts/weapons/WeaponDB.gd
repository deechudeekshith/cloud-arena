class_name WeaponDB
extends RefCounted

## Data-driven weapon + skin definitions. No behavior hardcoded in player.
## Hitscan, original designs.

const WEAPONS := [
	{
		"id": 0, "key": "rifle", "name": "AR-7 Vandal",
		"damage": 22.0, "head_mult": 1.8, "fire_rate": 9.0,
		"mag": 30, "reserve": 120, "reload_time": 1.9,
		"spread_deg": 1.4, "recoil": 0.028, "range": 90.0,
		"auto": true, "pellets": 1,
		"length": 0.78, "color": Color(0.16, 0.17, 0.2),
	},
	{
		"id": 1, "key": "smg", "name": "VK-9 Hornet",
		"damage": 14.0, "head_mult": 1.6, "fire_rate": 13.0,
		"mag": 32, "reserve": 128, "reload_time": 1.5,
		"spread_deg": 2.4, "recoil": 0.018, "range": 55.0,
		"auto": true, "pellets": 1,
		"length": 0.55, "color": Color(0.2, 0.22, 0.26),
	},
	{
		"id": 2, "key": "shotgun", "name": "M500 Breacher",
		"damage": 9.0, "head_mult": 1.5, "fire_rate": 1.4,
		"mag": 6, "reserve": 30, "reload_time": 2.4,
		"spread_deg": 4.5, "recoil": 0.09, "range": 28.0,
		"auto": false, "pellets": 8,
		"length": 0.85, "color": Color(0.25, 0.18, 0.12),
	},
]

const SKINS := [
	{"id": 0, "name": "Stock", "tint": Color(1, 1, 1), "emissive": Color(0, 0, 0)},
	{"id": 1, "name": "Desert", "tint": Color(0.85, 0.7, 0.45), "emissive": Color(0, 0, 0)},
	{"id": 2, "name": "Neon", "tint": Color(0.2, 0.25, 0.35), "emissive": Color(0.2, 0.8, 1.0)},
]

static func count() -> int:
	return WEAPONS.size()

static func get_weapon(id: int) -> Dictionary:
	return WEAPONS[clamp(id, 0, WEAPONS.size() - 1)]

static func get_skin(id: int) -> Dictionary:
	return SKINS[clamp(id, 0, SKINS.size() - 1)]
