#pragma once
#include "raylib.h"

// Hitscan tracers (replaces ballistic projectiles in FPS mode).
struct Projectile {
    Vector3 start{0, 0, 0};
    Vector3 end{0, 0, 0};
    float life = 0.0f;
    Color color = YELLOW;
    bool active = false;

    void Update(float dt);
    void Draw() const;
};
