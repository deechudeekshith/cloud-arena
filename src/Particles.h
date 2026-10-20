#pragma once
#include "raylib.h"

struct Tracer {
    Vector3 start{0, 0, 0};
    Vector3 end{0, 0, 0};
    float life = 0.0f;
    float maxLife = 0.09f;
    Color color = YELLOW;
    bool active = false;
};

struct Particle3D {
    Vector3 pos{0, 0, 0};
    Vector3 vel{0, 0, 0};
    float life = 0.0f;
    float maxLife = 1.0f;
    float size = 0.1f;
    Color color = WHITE;
    int kind = 0; // 0 puff, 1 spark, 2 blood, 3 ring, 4 float text uses dmg below
    bool active = false;
    int damage = 0;
    float vy = 0.0f; // for floating text
};

class ParticleSystem {
public:
    static const int MAXP = 600;
    static const int MAXT = 64;
    Particle3D p[MAXP];
    Tracer t[MAXT];

    void Update(float dt);
    void Draw() const; // 3D
    void DrawText2D(Camera3D cam, int screenW, int screenH) const; // floating damage numbers

    void AddTracer(Vector3 a, Vector3 b, Color c);
    void Muzzle(Vector3 pos, Vector3 dir);
    void Impact(Vector3 pos, Color c);
    void Blood(Vector3 pos, Vector3 dir);
    void DeathBurst(Vector3 pos, Color c);
    void RespawnBurst(Vector3 pos, Color c);
    void DamageNumber(Vector3 pos, int dmg);
    void Dust(Vector3 pos, int n);
};
