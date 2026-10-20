class_name ArenaConfig
extends RefCounted

## Shared tuning constants. Single source of truth for rules reused
## from the legacy 2D prototype (100 HP, 3s respawn, 180s match).

const MATCH_TIME_SEC := 180.0
const COUNTDOWN_SEC := 3.0
const RESPAWN_SEC := 3.0
const MAX_HP := 100.0

const TEAM_NAMES := ["BLUE", "RED"]
const TEAM_COLORS := [Color(0.25, 0.55, 1.0), Color(1.0, 0.35, 0.3)]
const PLAYERS_PER_TEAM := 4
const TOTAL_COMBATANTS := 8

# Physics layers (1-based for editor, bit-tested in code).
const L_WORLD := 1
const L_BODY := 2
const L_HEAD := 3
static func mask_world() -> int: return 1 << (L_WORLD - 1)
static func mask_body() -> int: return 1 << (L_BODY - 1)
static func mask_head() -> int: return 1 << (L_HEAD - 1)
static func mask_shot() -> int:
	return (1 << (L_WORLD - 1)) | (1 << (L_BODY - 1)) | (1 << (L_HEAD - 1))

# ──────────────────────────────────────────────────────────────
# TACTICAL MOVEMENT CONFIGURATION
# All speeds in m/s. Base normal speed is the single source of truth.
# ──────────────────────────────────────────────────────────────

const NORMAL_SPEED := 4.5          # Base walking speed (WASD)
const RUN_SPEED := 5.5             # Running (double-tap W or hold run key)
const CROUCH_SPEED := NORMAL_SPEED * 0.5      # ≈ 2.25 m/s
const PRONE_SPEED := NORMAL_SPEED / 4.0       # ≈ 1.125 m/s
const FORWARD_CRAWL_SPEED := NORMAL_SPEED / 4.0
const BACKWARD_CRAWL_SPEED := NORMAL_SPEED / 5.0
const SIDE_CRAWL_SPEED := NORMAL_SPEED / 6.0
const SPRINT_SPEED := NORMAL_SPEED * 1.5      # ≈ 6.75 m/s
const SPRINT_BURST_DURATION := 1.0            # seconds
const SPRINT_COOLDOWN := 1.5                  # seconds

const AIR_CONTROL := 0.25
const ACCEL_GROUND := 30.0
const FRICTION_GROUND := 24.0
const JUMP_VELOCITY := 5.0
const GRAVITY := 18.0
const MOUSE_SENS_DEFAULT := 0.0024

# Camera heights per stance (eye level from ground)
const CAM_STAND_H := 1.62
const CAM_CROUCH_H := 1.0
const CAM_PRONE_H := 0.25

# Capsule collision per stance
const CAPSULE_STAND_H := 1.8
const CAPSULE_STAND_R := 0.38
const CAPSULE_CROUCH_H := 1.1
const CAPSULE_CROUCH_R := 0.38
const CAPSULE_PRONE_H := 0.5
const CAPSULE_PRONE_R := 0.2

# Stance transition timing
const STANCE_TRANSITION_TIME := 0.15

# Ammo system
const MAX_RESERVE_RIFLE := 90
const MAX_RESERVE_SMG := 96
const MAX_RESERVE_SHOTGUN := 18
const AMMO_PICKUP_RESPAWN := 30.0

# Movement state enumeration
enum MoveState {
	STANDING = 0,
	RUNNING = 1,
	SPRINTING = 2,
	CROUCHING = 3,
	PRONE = 4,
	CRAWLING = 5,
	JUMPING = 6,
	FALLING = 7
}

static func get_state_name(state: int) -> String:
	match state:
		MoveState.STANDING: return "STANDING"
		MoveState.RUNNING: return "RUNNING"
		MoveState.SPRINTING: return "SPRINTING"
		MoveState.CROUCHING: return "CROUCHING"
		MoveState.PRONE: return "PRONE"
		MoveState.CRAWLING: return "CRAWLING"
		MoveState.JUMPING: return "JUMPING"
		MoveState.FALLING: return "FALLING"
	return "UNKNOWN"