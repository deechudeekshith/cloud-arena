#include "Player.h"
#include <cmath>

static WeaponDef WEAPONS[2] = {
    {"RIFLE", 20, 0.22f, 30, 1.6f, 0.012f, 80.0f, {140, 255, 150, 255}},
    {"SMG", 12, 0.11f, 40, 1.4f, 0.030f, 55.0f, {255, 210, 120, 255}},
};

const WeaponDef* GetWeapons(int* count) {
    if (count) *count = 2;
    return WEAPONS;
}

static float ClampF(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }
static float LerpF(float a, float b, float t) { return a + (b - a) * t; }

void Player::Init(int pid, const std::string& pname, Color c, int av, bool bot, BotPersonality p, float spd) {
    id = pid;
    name = pname;
    color = c;
    avatar = av;
    isBot = bot;
    personality = p;
    speed = spd;
    health = 100;
    displayHealth = 100;
    score = kills = deaths = 0;
    alive = true;
    respawnTimer = 0;
    fireCooldown = 0;
    weapon = 0;
    ammo = WEAPONS[0].mag;
    reloadTimer = -1;
    kick = 0;
    yaw = 0;
    pitch = 0;
    vel = {0, 0, 0};
    animState = AnimState::Idle;
    animTime = 0;
    speedFrac = 0;
    hitFlash = 0;
    deathT = 0;
    bobT = 0;
    aiStrafeDir = (pid % 2 == 0) ? 1.0f : -1.0f;
    aiStrafeTimer = 1.0f + (float)(pid % 3) * 0.4f;
    aiWanderAngle = (float)pid * 1.7f;
}

void Player::Reset(Vector3 spawn, float faceYaw) {
    pos = spawn;
    vel = {0, 0, 0};
    yaw = faceYaw;
    pitch = 0;
    health = 100;
    displayHealth = 100;
    alive = true;
    respawnTimer = 0;
    fireCooldown = 0.3f;
    ammo = WEAPONS[weapon].mag;
    reloadTimer = -1;
    kick = 0;
    animState = AnimState::Respawn;
    animTime = 0;
    hitFlash = 0;
    deathT = 1.0f;
}

void Player::UpdateAnim(float dt) {
    displayHealth = (int)LerpF((float)displayHealth, (float)health, ClampF(dt * 10, 0, 1));
    if (hitFlash > 0) hitFlash -= dt * 6.0f;
    if (kick > 0) kick = ClampF(kick - dt * 7.0f, 0, 1);
    if (!alive) {
        deathT -= dt * 1.4f;
        return;
    }
    float sp = sqrtf(vel.x * vel.x + vel.z * vel.z);
    speedFrac = ClampF(sp / speed, 0, 1.4f);
    animTime += dt * (0.6f + speedFrac);
    bobT += dt * (1.0f + speedFrac * 2.0f);
    if (fireCooldown > 0.1f)
        animState = AnimState::Shoot;
    else if (hitFlash > 0)
        animState = AnimState::Hit;
    else if (speedFrac > 0.75f)
        animState = AnimState::Run;
    else if (speedFrac > 0.08f)
        animState = AnimState::Walk;
    else
        animState = AnimState::Idle;
}

void Player::ApplyHit(float dmg, Vector3 dir) {
    health = (int)ClampF(health - dmg, 0, 100);
    hitFlash = 1.0f;
    float l = sqrtf(dir.x * dir.x + dir.z * dir.z);
    if (l > 0.01f) {
        vel.x += dir.x / l * 1.6f;
        vel.z += dir.z / l * 1.6f;
    }
}

void Player::StartDeath() {
    alive = false;
    deaths += 1;
    animState = AnimState::Death;
    deathT = 1.0f;
    vel = {0, 0, 0};
}

Vector3 Player::LookDir() const {
    float cp = cosf(pitch);
    return {cosf(yaw) * cp, sinf(pitch), sinf(yaw) * cp};
}
