#include "Particles.h"
#include <cmath>
#include <cstdio>
#include <cstdlib>

static float RandF(float a, float b) { return a + (float)rand() / (float)RAND_MAX * (b - a); }

static Particle3D* FreeP(Particle3D* arr, int n) {
    for (int i = 0; i < n; i++)
        if (!arr[i].active) return &arr[i];
    return nullptr;
}

void ParticleSystem::Update(float dt) {
    for (int i = 0; i < MAXP; i++) {
        Particle3D& q = p[i];
        if (!q.active) continue;
        q.life -= dt;
        if (q.life <= 0) { q.active = false; continue; }
        if (q.kind == 4) { // floating text rises
            q.vy -= dt * 0.4f;
            q.pos.y += (1.2f + q.vy) * dt;
            continue;
        }
        q.vel.y -= (q.kind == 1 ? 6.0f : 2.5f) * dt;
        q.vel.x *= 0.985f;
        q.vel.z *= 0.985f;
        q.pos.x += q.vel.x * dt;
        q.pos.y += q.vel.y * dt;
        q.pos.z += q.vel.z * dt;
        if (q.pos.y < 0.03f) { q.pos.y = 0.03f; q.vel.y = 0; }
    }
    for (int i = 0; i < MAXT; i++) {
        if (!t[i].active) continue;
        t[i].life -= dt;
        if (t[i].life <= 0) t[i].active = false;
    }
}

void ParticleSystem::Draw() const {
    for (int i = 0; i < MAXT; i++) {
        if (!t[i].active) continue;
        float a = t[i].life / t[i].maxLife;
        Color c = t[i].color;
        c.a = (unsigned char)(255 * a);
        DrawLine3D(t[i].start, t[i].end, c);
        DrawSphere(t[i].end, 0.06f, c);
    }
    for (int i = 0; i < MAXP; i++) {
        const Particle3D& q = p[i];
        if (!q.active || q.kind == 4) continue;
        float a = q.life / q.maxLife;
        Color c = q.color;
        c.a = (unsigned char)(c.a * (a > 1 ? 1 : a));
        if (q.kind == 3) {
            DrawSphereWires(q.pos, q.size * (1.6f - a), 8, 6, c);
        } else {
            DrawSphere(q.pos, q.size * (0.5f + 0.5f * a), c);
        }
    }
}

void ParticleSystem::DrawText2D(Camera3D cam, int screenW, int screenH) const {
    (void)screenW;
    (void)screenH;
    for (int i = 0; i < MAXP; i++) {
        const Particle3D& q = p[i];
        if (!q.active || q.kind != 4) continue;
        Vector2 s = GetWorldToScreen(q.pos, cam);
        float a = q.life / q.maxLife;
        char buf[16];
        snprintf(buf, sizeof(buf), "-%d", q.damage);
        int fs = 16;
        int tw = MeasureText(buf, fs);
        DrawText(buf, (int)(s.x - tw / 2), (int)s.y, fs, {255, 230, 120, (unsigned char)(255 * a)});
    }
}

void ParticleSystem::AddTracer(Vector3 a, Vector3 b, Color c) {
    for (int i = 0; i < MAXT; i++) {
        if (!t[i].active) {
            t[i].start = a;
            t[i].end = b;
            t[i].life = t[i].maxLife = 0.09f;
            t[i].color = c;
            t[i].active = true;
            return;
        }
    }
}

void ParticleSystem::Muzzle(Vector3 pos, Vector3 dir) {
    for (int i = 0; i < 4; i++) {
        Particle3D* q = FreeP(p, MAXP);
        if (!q) return;
        q->pos = pos;
        q->vel = {dir.x * RandF(1, 3) + RandF(-1, 1), RandF(0.5f, 2.0f), dir.z * RandF(1, 3) + RandF(-1, 1)};
        q->life = q->maxLife = RandF(0.12f, 0.3f);
        q->size = RandF(0.08f, 0.2f);
        q->color = {255, (unsigned char)RandF(180, 230), 120, 220};
        q->kind = 0;
        q->active = true;
    }
}

void ParticleSystem::Impact(Vector3 pos, Color c) {
    for (int i = 0; i < 7; i++) {
        Particle3D* q = FreeP(p, MAXP);
        if (!q) return;
        q->pos = pos;
        q->vel = {RandF(-3, 3), RandF(1, 4), RandF(-3, 3)};
        q->life = q->maxLife = RandF(0.25f, 0.55f);
        q->size = RandF(0.05f, 0.14f);
        q->color = c;
        q->color.a = 220;
        q->kind = (i % 3 == 0) ? 1 : 0;
        q->active = true;
    }
}

void ParticleSystem::Blood(Vector3 pos, Vector3 dir) {
    for (int i = 0; i < 8; i++) {
        Particle3D* q = FreeP(p, MAXP);
        if (!q) return;
        q->pos = pos;
        q->vel = {dir.x * RandF(1, 3) + RandF(-2, 2), RandF(0.5f, 3.0f), dir.z * RandF(1, 3) + RandF(-2, 2)};
        q->life = q->maxLife = RandF(0.3f, 0.6f);
        q->size = RandF(0.06f, 0.15f);
        q->color = {200, 30, 30, 230};
        q->kind = 2;
        q->active = true;
    }
}

void ParticleSystem::DeathBurst(Vector3 pos, Color c) {
    for (int i = 0; i < 16; i++) {
        Particle3D* q = FreeP(p, MAXP);
        if (!q) return;
        float a = RandF(0, 6.28f);
        q->pos = {pos.x, pos.y + RandF(0.2f, 1.2f), pos.z};
        q->vel = {cosf(a) * RandF(1, 4), RandF(1, 4), sinf(a) * RandF(1, 4)};
        q->life = q->maxLife = RandF(0.4f, 0.8f);
        q->size = RandF(0.08f, 0.2f);
        q->color = (i % 2) ? c : Color{200, 30, 30, 230};
        q->color.a = 230;
        q->kind = 2;
        q->active = true;
    }
}

void ParticleSystem::RespawnBurst(Vector3 pos, Color c) {
    for (int i = 0; i < 10; i++) {
        Particle3D* q = FreeP(p, MAXP);
        if (!q) return;
        float a = (float)i / 10.0f * 6.28f;
        q->pos = {pos.x + cosf(a) * 0.5f, 0.9f, pos.z + sinf(a) * 0.5f};
        q->vel = {cosf(a) * 1.5f, 0.6f, sinf(a) * 1.5f};
        q->life = q->maxLife = 0.7f;
        q->size = 0.5f;
        q->color = c;
        q->color.a = 200;
        q->kind = 3;
        q->active = true;
    }
}

void ParticleSystem::DamageNumber(Vector3 pos, int dmg) {
    Particle3D* q = FreeP(p, MAXP);
    if (!q) return;
    q->pos = {pos.x + RandF(-0.3f, 0.3f), pos.y + 1.9f, pos.z};
    q->vy = 0;
    q->life = q->maxLife = 0.8f;
    q->kind = 4;
    q->damage = dmg;
    q->active = true;
}

void ParticleSystem::Dust(Vector3 pos, int n) {
    for (int i = 0; i < n; i++) {
        Particle3D* q = FreeP(p, MAXP);
        if (!q) return;
        q->pos = {pos.x + RandF(-0.2f, 0.2f), 0.08f, pos.z + RandF(-0.2f, 0.2f)};
        q->vel = {RandF(-0.6f, 0.6f), RandF(0.4f, 1.2f), RandF(-0.6f, 0.6f)};
        q->life = q->maxLife = RandF(0.3f, 0.6f);
        q->size = RandF(0.08f, 0.18f);
        q->color = {150, 140, 120, 140};
        q->kind = 0;
        q->active = true;
    }
}
