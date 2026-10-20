#pragma once
#include "raylib.h"
#include <string>

enum class BotPersonality { None, Aggressive, Balanced, Defensive };
enum class AnimState { Idle, Walk, Run, Shoot, Hit, Death, Respawn };

struct WeaponDef {
    const char* name;
    int damage;
    float interval;
    int mag;
    float reloadTime;
    float spread;   // radians random cone
    float range;
    Color tracer;
};

const WeaponDef* GetWeapons(int* count);

struct Player {
    int id = 0;
    std::string name = "Player";
    Color color = WHITE;
    int avatar = 0;

    Vector3 pos{0, 0, 0}; // feet position
    Vector3 vel{0, 0, 0};
    float yaw = 0.0f;     // facing / look yaw
    float pitch = 0.0f;   // human look pitch
    float eyeH = 1.6f;
    float eyeTarget = 1.6f;
    float yVel = 0.0f;
    bool onGround = true;
    float radius = 0.45f;
    float speed = 7.0f;
    float accel = 40.0f;

    int health = 100;
    int displayHealth = 100;
    int score = 0;
    int kills = 0;
    int deaths = 0;
    bool alive = true;
    float respawnTimer = 0.0f;
    float fireCooldown = 0.0f;

    int weapon = 0; // 0 rifle, 1 smg
    int ammo = 30;
    float reloadTimer = -1.0f; // <0 not reloading
    float kick = 0.0f;         // viewmodel recoil 0..1

    bool isBot = false;
    BotPersonality personality = BotPersonality::None;

    // Animation
    AnimState animState = AnimState::Idle;
    float animTime = 0.0f;
    float speedFrac = 0.0f;
    float hitFlash = 0.0f;
    float deathT = 0.0f;
    float bobT = 0.0f;

    // Bot AI state
    float aiStrafeDir = 1.0f;
    float aiStrafeTimer = 0.0f;
    float aiWanderAngle = 0.0f;

    void Init(int pid, const std::string& pname, Color c, int av, bool bot, BotPersonality p, float spd);
    void Reset(Vector3 spawn, float faceYaw);
    void UpdateAnim(float dt);
    void ApplyHit(float dmg, Vector3 dir);
    void StartDeath();
    Vector3 Eye() const { return {pos.x, pos.y + eyeH, pos.z}; }
    Vector3 LookDir() const;
};
