#pragma once
#include "raylib.h"

// Original avatar presets (color/material variations on one base rig).
struct AvatarPreset {
    const char* name;
    Color jacket;
    Color pants;
    Color skin;
    Color vest;
    Color boots;
};

const AvatarPreset* GetAvatars(int* count);
const AvatarPreset& GetAvatar(int idx);

// Full third-person humanoid (feet position, yaw facing). Procedural walk anim.
void DrawHumanoid(Vector3 feetPos, float yaw, const AvatarPreset& av,
                  float animTime, float speedFrac, bool shooting,
                  bool alive, float deathT, float hitFlash);

// First-person weapon viewmodel (screen space, after EndMode3D).
// weapon: 0 rifle, 1 smg. bobT = anim time, bobAmt 0..1, kick 0..1 recoil,
// reloading 0..1 progress (-1 = not reloading), ammo/mag for display.
void DrawWeaponView(int weapon, float bobT, float bobAmt, float kick, float reloading,
                    int ammo, int mag, int screenW, int screenH);
