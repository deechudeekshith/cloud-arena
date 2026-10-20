#include "Humanoid.h"
#include <cmath>
#include <cstdio>

static AvatarPreset AVATARS[6] = {
    {"Tactical", {45, 60, 50, 255}, {35, 38, 45, 255}, {210, 170, 140, 255}, {60, 70, 60, 255}, {40, 32, 26, 255}},
    {"Assault", {100, 60, 40, 255}, {60, 55, 45, 255}, {200, 160, 130, 255}, {50, 45, 40, 255}, {45, 35, 28, 255}},
    {"Recon", {50, 70, 80, 255}, {40, 45, 55, 255}, {215, 175, 145, 255}, {35, 50, 60, 255}, {35, 30, 28, 255}},
    {"Urban", {70, 72, 78, 255}, {45, 47, 52, 255}, {205, 165, 135, 255}, {90, 92, 100, 255}, {30, 30, 32, 255}},
    {"Desert", {150, 125, 90, 255}, {110, 95, 70, 255}, {220, 180, 150, 255}, {120, 100, 75, 255}, {70, 55, 40, 255}},
    {"Stealth", {25, 28, 40, 255}, {22, 24, 32, 255}, {195, 155, 125, 255}, {40, 45, 70, 255}, {25, 22, 25, 255}},
};

const AvatarPreset* GetAvatars(int* count) {
    if (count) *count = 6;
    return AVATARS;
}
const AvatarPreset& GetAvatar(int idx) {
    idx = ((idx % 6) + 6) % 6;
    return AVATARS[idx];
}

// Local helper: limb box rotated around a pivot (for arms/legs swing).
static void DrawLimb(Vector3 pivot, float yaw, float swing, float len, float thick, Color c) {
    // limb hangs down (-Y), swung forward/back around local X axis
    Vector3 dir{cosf(yaw) * sinf(swing), -cosf(swing), sinf(yaw) * sinf(swing)};
    Vector3 mid{pivot.x + dir.x * len / 2, pivot.y + dir.y * len / 2, pivot.z + dir.z * len / 2};
    DrawCube(mid, thick, len, thick, c);
}

void DrawHumanoid(Vector3 feet, float yaw, const AvatarPreset& av,
                  float animTime, float speedFrac, bool shooting,
                  bool alive, float deathT, float hitFlash) {
    if (!alive) {
        // Fallen: fade + sink
        float a = deathT > 0 ? deathT : 0.0f;
        if (a < 0) a = 0;
        if (a > 1) a = 1;
        unsigned char alpha = (unsigned char)(200 * a);
        Vector3 p{feet.x, feet.y + 0.25f * a, feet.z};
        // body lying: horizontal torso + head
        Vector3 f{cosf(yaw), 0, sinf(yaw)};
        Vector3 torso{p.x, p.y + 0.2f, p.z};
        DrawCube(torso, 0.55f, 0.35f, 0.9f, {av.jacket.r, av.jacket.g, av.jacket.b, alpha});
        Vector3 head{torso.x + f.x * 0.65f, torso.y + 0.05f, torso.z + f.z * 0.65f};
        DrawSphere(head, 0.22f, {av.skin.r, av.skin.g, av.skin.b, alpha});
        DrawCircle3D(feet, 0.9f, {1, 0, 0}, 90.0f, {150, 30, 30, (unsigned char)(90 * a)});
        return;
    }

    Color jacket = av.jacket, pants = av.pants, skin = av.skin, vest = av.vest, boots = av.boots;
    if (hitFlash > 0) {
        float f = hitFlash > 1 ? 1 : hitFlash;
        jacket = {255, (unsigned char)(jacket.g + (255 - jacket.g) * f * 0.6f), (unsigned char)(jacket.b + (255 - jacket.b) * f * 0.6f), 255};
    }

    float freq = 9.0f;
    float amp = 0.55f * (speedFrac > 1 ? 1 : speedFrac);
    if (speedFrac < 0.05f) { freq = 2.0f; amp = 0.03f; } // idle breathing
    float sw = sinf(animTime * freq) * amp;
    float bob = fabsf(cosf(animTime * freq)) * 0.06f * (speedFrac > 0.05f ? 1 : 0.3f);

    Vector3 f{cosf(yaw), 0, sinf(yaw)};
    Vector3 r{-sinf(yaw), 0, cosf(yaw)};

    // blob shadow
    DrawCircle3D(feet, 0.55f, {1, 0, 0}, 90.0f, {0, 0, 0, 60});

    float hipY = feet.y + 0.85f + bob;
    // Legs (pivot at hips)
    Vector3 hipL{feet.x + r.x * 0.14f, hipY, feet.z + r.z * 0.14f};
    Vector3 hipR{feet.x - r.x * 0.14f, hipY, feet.z - r.z * 0.14f};
    DrawLimb(hipL, yaw, sw, 0.8f, 0.16f, pants);
    DrawLimb(hipR, yaw, -sw, 0.8f, 0.16f, pants);
    // boots
    Vector3 bootL{hipL.x + f.x * sinf(sw) * 0.8f, feet.y + 0.08f, hipL.z + f.z * sinf(sw) * 0.8f};
    Vector3 bootR{hipR.x + f.x * sinf(-sw) * 0.8f, feet.y + 0.08f, hipR.z + f.z * sinf(-sw) * 0.8f};
    DrawCube(bootL, 0.18f, 0.16f, 0.3f, boots);
    DrawCube(bootR, 0.18f, 0.16f, 0.3f, boots);

    // Torso
    Vector3 torso{feet.x, hipY + 0.42f, feet.z};
    DrawCube(torso, 0.5f, 0.62f, 0.32f, jacket);
    // vest plate (front)
    DrawCube({torso.x + f.x * 0.16f, torso.y, torso.z + f.z * 0.16f}, 0.4f, 0.45f, 0.1f, vest);
    // head
    Vector3 head{feet.x + f.x * 0.05f, hipY + 0.95f, feet.z + f.z * 0.05f};
    DrawSphere(head, 0.21f, skin);
    // helmet cap
    DrawSphere({head.x, head.y + 0.07f, head.z}, 0.22f, vest);

    // Arms: left swings, right holds gun forward (aim pose), swings slightly when sprinting
    float shY = hipY + 0.62f;
    Vector3 shL{feet.x + r.x * 0.33f, shY, feet.z + r.z * 0.33f};
    Vector3 shR{feet.x - r.x * 0.33f, shY, feet.z - r.z * 0.33f};
    DrawLimb(shL, yaw, -sw * 0.8f, 0.6f, 0.13f, jacket);
    // right arm forward holding gun
    Vector3 gunBase{shR.x + f.x * 0.35f, shR.y - 0.25f, shR.z + f.z * 0.35f};
    DrawCube({(shR.x + gunBase.x) / 2, (shR.y + gunBase.y) / 2, (shR.z + gunBase.z) / 2}, 0.13f, 0.13f, 0.55f, jacket);
    // gun
    float gunLen = 0.7f + (shooting ? 0.06f : 0);
    Vector3 gunTip{gunBase.x + f.x * gunLen, gunBase.y, gunBase.z + f.z * gunLen};
    DrawCube({(gunBase.x + gunTip.x) / 2, (gunBase.y + gunTip.y) / 2, (gunBase.z + gunTip.z) / 2}, 0.09f, 0.09f,
             gunLen, {35, 35, 40, 255});
    if (shooting) {
        DrawSphere(gunTip, 0.16f, {255, 220, 120, 255});
    }
}

void DrawWeaponView(int weapon, float bobT, float bobAmt, float kick, float reloading,
                    int ammo, int mag, int screenW, int screenH) {
    float bx = sinf(bobT * 9.0f) * 8.0f * bobAmt;
    float by = fabsf(cosf(bobT * 9.0f)) * 7.0f * bobAmt - kick * 26.0f;
    float gx = screenW - 300 + bx;
    float gy = screenH - 150 + by;

    // hands
    DrawCircleV({gx - 40, gy + 60}, 26, {200, 160, 130, 255});
    DrawCircleV({gx + 60, gy + 30}, 24, {195, 155, 125, 255});
    // gun body
    Color gun = weapon == 0 ? Color{45, 48, 55, 255} : Color{60, 55, 70, 255};
    DrawRectangleRec({gx - 60, gy, 220, 44}, gun);
    DrawRectangleRec({gx - 60, gy, 220, 10}, {70, 74, 84, 255});
    // barrel + stock + mag
    DrawRectangleRec({gx + 150, gy + 12, weapon == 0 ? 90 : 60, 16}, {30, 30, 34, 255});
    DrawRectangleRec({gx - 110, gy + 8, 44, 30}, {38, 40, 46, 255});
    DrawRectangleRec({gx + 40, gy + 40, 26, weapon == 0 ? 44 : 34}, {50, 44, 40, 255});
    // sight
    DrawRectangleRec({gx + 60, gy - 16, 10, 18}, {30, 30, 34, 255});
    DrawCircleV({gx + 65, gy - 8}, 3, {120, 255, 140, 255});

    if (kick > 0.4f) { // muzzle flash
        float f = kick;
        Vector2 tip{gx + 150 + (weapon == 0 ? 90 : 60), gy + 20};
        DrawCircleV(tip, 26 * f, {255, 220, 120, (unsigned char)(230 * f)});
        DrawCircleV(tip, 12 * f, {255, 255, 220, (unsigned char)(255 * f)});
    }
    if (reloading >= 0) { // reload spinner bar
        DrawRectangleRec({gx - 60, gy - 34, 220, 12}, {20, 20, 20, 220});
        DrawRectangleRec({gx - 60, gy - 34, 220 * reloading, 12}, SKYBLUE);
        DrawText("RELOADING", (int)(gx - 60), (int)(gy - 56), 14, SKYBLUE);
    }
    // ammo handled by HUD; keep viewmodel clean
    (void)ammo;
    (void)mag;
}
