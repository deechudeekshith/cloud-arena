#include "Arena.h"
#include <cmath>
#include <cstdlib>

static float DistXZ(Vector3 a, Vector3 b) {
    float dx = a.x - b.x, dz = a.z - b.z;
    return sqrtf(dx * dx + dz * dz);
}
static BoundingBox ToBBox(const SolidBox& b) {
    return {{b.center.x - b.size.x / 2, 0.0f, b.center.z - b.size.z / 2},
            {b.center.x + b.size.x / 2, b.size.y, b.center.z + b.size.z / 2}};
}
static bool CircleHitsBox(float x, float z, float r, const SolidBox& b) {
    float cx = x, cz = z;
    if (cx < b.center.x - b.size.x / 2) cx = b.center.x - b.size.x / 2;
    if (cx > b.center.x + b.size.x / 2) cx = b.center.x + b.size.x / 2;
    if (cz < b.center.z - b.size.z / 2) cz = b.center.z - b.size.z / 2;
    if (cz > b.center.z + b.size.z / 2) cz = b.center.z + b.size.z / 2;
    float dx = x - cx, dz = z - cz;
    return dx * dx + dz * dz < r * r;
}

void Arena::Init() {
    center = {0, 0, 0};
    radius = 32.0f;
    srand(4242);

    boxes.clear();
    auto addBox = [&](float x, float z, float w, float h, float d, Color c, Color e, bool crate) {
        Vector3 p{x, 0, z};
        // keep well inside circle
        float need = sqrtf(w * w + d * d) / 2.0f + 3.0f;
        if (DistXZ(p, center) + need > radius) return;
        // keep spawns clear (checked later loosely)
        SolidBox b;
        b.center = {x, h / 2.0f, z};
        b.size = {w, h, d};
        b.color = c;
        b.edge = e;
        b.crate = crate;
        boxes.push_back(b);
    };

    Color bld = {74, 94, 144, 255}, bldE = {126, 164, 232, 255};
    Color crt = {150, 110, 64, 255}, crtE = {200, 160, 100, 255};
    Color con = {120, 122, 134, 255};

    // Central building cluster (high-conflict zone, open middle kept walkable)
    addBox(-5.5f, -5.5f, 5.0f, 2.6f, 2.0f, bld, bldE, false);
    addBox(5.5f, -5.5f, 5.0f, 2.6f, 2.0f, bld, bldE, false);
    addBox(-5.5f, 5.5f, 5.0f, 2.6f, 2.0f, bld, bldE, false);
    addBox(5.5f, 5.5f, 5.0f, 2.6f, 2.0f, bld, bldE, false);
    // Elevated platform look: low wide block at center-east/west? keep center open
    addBox(0, -11.0f, 3.0f, 1.2f, 3.0f, crt, crtE, true);
    addBox(0, 11.0f, 3.0f, 1.2f, 3.0f, crt, crtE, true);

    // NORTH (warehouse + containers)
    addBox(-14.0f, -17.0f, 7.0f, 4.5f, 5.0f, bld, bldE, false); // warehouse
    addBox(-5.0f, -18.0f, 4.0f, 2.4f, 2.2f, con, bldE, false);  // container
    addBox(-5.0f, -15.2f, 4.0f, 2.4f, 2.2f, crt, crtE, false);
    addBox(8.0f, -17.0f, 3.0f, 1.2f, 3.0f, crt, crtE, true);

    // EAST (compound walls + road cover)
    addBox(17.0f, -6.0f, 1.0f, 2.2f, 9.0f, con, bldE, false);
    addBox(17.0f, 6.0f, 1.0f, 2.2f, 9.0f, con, bldE, false);
    addBox(13.0f, 0.0f, 3.0f, 1.2f, 3.0f, crt, crtE, true);

    // SOUTH (open field + rocks as blocks + small structures)
    addBox(-8.0f, 17.0f, 4.0f, 2.8f, 4.0f, bld, bldE, false);
    addBox(6.0f, 18.0f, 3.0f, 1.4f, 2.0f, crt, crtE, true);
    addBox(12.0f, 14.0f, 2.5f, 1.8f, 2.5f, con, bldE, false);

    // WEST (industrial: barriers + containers + buildings)
    addBox(-17.0f, 2.0f, 5.0f, 3.5f, 4.0f, bld, bldE, false);
    addBox(-13.0f, -6.0f, 4.0f, 2.4f, 2.2f, con, bldE, false);
    addBox(-19.0f, -6.0f, 2.0f, 1.2f, 6.0f, crt, crtE, true);

    // Scattered waist-high cover
    addBox(-10.0f, 8.0f, 2.2f, 1.1f, 2.2f, crt, crtE, true);
    addBox(10.0f, -8.0f, 2.2f, 1.1f, 2.2f, crt, crtE, true);
    addBox(-10.0f, -8.0f, 2.2f, 1.1f, 2.2f, crt, crtE, true);
    addBox(10.0f, 8.0f, 2.2f, 1.1f, 2.2f, crt, crtE, true);

    // Ground patches: roads crossing + pads
    ground.clear();
    ground.push_back({{0, 0.02f, 0}, 3.2f, 56.0f, {139, 109, 71, 255}, false}); // N-S road
    ground.push_back({{0, 0.02f, 0}, 56.0f, 3.2f, {139, 109, 71, 255}, false}); // E-W road
    ground.push_back({{0, 0.03f, 0}, 7.0f, 0, {112, 116, 128, 255}, true});     // center plaza
    ground.push_back({{-14.0f, 0.02f, -17.0f}, 9.0f, 7.0f, {88, 92, 104, 255}, false});
    ground.push_back({{-17.0f, 0.02f, 2.0f}, 7.0f, 6.0f, {88, 92, 104, 255}, false});

    // Decor ring (trees/rocks outside play + few inside clear spots)
    decor.clear();
    for (int i = 0; i < 46; i++) {
        float a = (float)i / 46.0f * 2 * 3.14159f + (float)(rand() % 100) / 400.0f;
        float rr = radius - 2.5f - (float)(rand() % 40) / 10.0f;
        if (i % 3 == 0) rr = radius + 2.0f + (float)(rand() % 60) / 10.0f;
        Vector3 p{center.x + cosf(a) * rr, 0, center.z + sinf(a) * rr};
        bool blocked = false;
        for (const auto& b : boxes) {
            if (CircleHitsBox(p.x, p.z, 1.2f, b)) { blocked = true; break; }
        }
        if (blocked && rr < radius) continue;
        Decor3D d;
        d.pos = p;
        d.kind = i % 3;
        d.phase = (float)(rand() % 100) / 100.0f * 6.28f;
        d.size = d.kind == 0 ? 1.4f : (d.kind == 1 ? 1.0f : 0.8f);
        decor.push_back(d);
    }

    // 8 spawns around circle
    spawns.clear();
    float sr = radius * 0.72f;
    float angles[8] = {-2.55f, -1.75f, -0.95f, -0.35f, 0.55f, 1.35f, 2.05f, 2.85f};
    for (int i = 0; i < 8; i++) {
        Vector3 s{center.x + cosf(angles[i]) * sr, 0, center.z + sinf(angles[i]) * sr};
        for (int t = 0; t < 10 && CollidesXZ(s, 1.0f); t++) {
            s.x += (center.x - s.x) * 0.08f;
            s.z += (center.z - s.z) * 0.08f;
        }
        spawns.push_back(s);
    }
}

bool Arena::InsideArena(Vector3 p, float margin) const {
    return DistXZ(p, center) <= radius - margin;
}

bool Arena::CollidesXZ(Vector3 p, float r) const {
    if (!InsideArena(p, r)) return true;
    for (const auto& b : boxes) {
        if (CircleHitsBox(p.x, p.z, r, b)) return true;
    }
    return false;
}

Vector3 Arena::MoveCollide(Vector3 p, Vector3 delta, float r) const {
    Vector3 nx{p.x + delta.x, p.y, p.z};
    bool hx = CollidesXZ(nx, r);
    if (!hx) p.x = nx.x;
    Vector3 nz{p.x, p.y, p.z + delta.z};
    bool hz = CollidesXZ(nz, r);
    if (!hz) p.z = nz.z;
    p.y += delta.y;
    if (p.y < 0) p.y = 0;
    return p;
}

bool Arena::SegmentBlocked(Vector3 a, Vector3 b) const {
    Vector3 d{b.x - a.x, b.y - a.y, b.z - a.z};
    float len = sqrtf(d.x * d.x + d.y * d.y + d.z * d.z);
    if (len < 0.001f) return false;
    int steps = (int)(len / 0.6f) + 1;
    for (int i = 1; i < steps; i++) {
        float t = (float)i / (float)steps;
        Vector3 p{a.x + d.x * t, a.y + d.y * t, a.z + d.z * t};
        for (const auto& box : boxes) {
            BoundingBox bb = ToBBox(box);
            if (p.x > bb.min.x && p.x < bb.max.x && p.y > bb.min.y && p.y < bb.max.y &&
                p.z > bb.min.z && p.z < bb.max.z)
                return true;
        }
    }
    return false;
}

float Arena::RayHitBox(Ray ray, Vector3* hitPoint) const {
    float best = -1.0f;
    Vector3 bestP{0, 0, 0};
    for (const auto& box : boxes) {
        RayCollision c = GetRayCollisionBox(ray, ToBBox(box));
        if (c.hit && (best < 0 || c.distance < best)) {
            best = c.distance;
            bestP = c.point;
        }
    }
    if (best >= 0 && hitPoint) *hitPoint = bestP;
    return best;
}

Vector3 Arena::GetSpawn(int i) const {
    if (spawns.empty()) return center;
    int n = (int)spawns.size();
    i = ((i % n) + n) % n;
    return spawns[(size_t)i];
}

float Arena::GetYawToCenter(Vector3 p) const {
    return atan2f(center.z - p.z, center.x - p.x);
}

void Arena::DrawGround() const {
    // Outer terrain
    DrawPlane({0, -0.05f, 0}, {140, 140}, {26, 60, 34, 255});
    // Arena disc
    DrawCircle3D(center, radius + 2.0f, {1, 0, 0}, 90.0f, {40, 96, 50, 255});
    DrawCircle3D({center.x, 0.01f, center.z}, radius, {1, 0, 0}, 90.0f, {43, 102, 54, 255});
    for (const auto& g : ground) {
        if (g.circle) {
            DrawCircle3D({g.pos.x, 0.03f, g.pos.z}, g.w, {1, 0, 0}, 90.0f, g.color);
        } else {
            DrawCube({g.pos.x, 0.02f, g.pos.z}, g.w, 0.04f, g.d, g.color);
        }
    }
}

void Arena::DrawSolids() const {
    for (const auto& b : boxes) {
        // fake shadow blob
        DrawCircle3D({b.center.x, 0.02f, b.center.z}, (b.size.x + b.size.z) / 4.0f + 0.4f, {1, 0, 0}, 90.0f,
                     {0, 0, 0, 50});
        DrawCube(b.center, b.size.x, b.size.y, b.size.z, b.color);
        DrawCubeWires(b.center, b.size.x, b.size.y, b.size.z, b.edge);
        // top highlight slab
        DrawCube({b.center.x, b.size.y + 0.01f, b.center.z}, b.size.x * 0.96f, 0.03f, b.size.z * 0.96f,
                 {255, 255, 255, 30});
    }
    // Center landmark pylon
    DrawCube({center.x, 1.0f, center.z}, 0.8f, 2.0f, 0.8f, {150, 170, 220, 255});
    DrawCubeWires({center.x, 1.0f, center.z}, 0.8f, 2.0f, 0.8f, WHITE);
}

void Arena::DrawDecor(float time) const {
    for (const auto& d : decor) {
        if (d.kind == 0) { // tree
            float sway = sinf(time * 1.4f + d.phase) * 0.08f;
            DrawCylinder({d.pos.x, 0.5f, d.pos.z}, 0.12f, 0.16f, 1.0f, 6, {110, 78, 44, 255});
            DrawSphere({d.pos.x + sway, 1.6f, d.pos.z}, d.size, {28, 86, 38, 255});
            DrawSphere({d.pos.x - 0.4f + sway, 1.2f, d.pos.z}, d.size * 0.6f, {46, 128, 58, 255});
        } else if (d.kind == 1) { // rock
            DrawSphere({d.pos.x, 0.3f, d.pos.z}, d.size, {110, 112, 124, 255});
            DrawSphere({d.pos.x - 0.2f, 0.5f, d.pos.z}, d.size * 0.55f, {140, 142, 154, 255});
        } else { // bush
            float sway = sinf(time * 1.8f + d.phase) * 0.05f;
            DrawSphere({d.pos.x + sway, 0.35f, d.pos.z}, d.size, {34, 100, 46, 255});
        }
    }
}

void Arena::DrawBoundary() const {
    // Energy boundary ring: translucent wall + posts
    DrawCylinderWires(center, radius, radius, 4.0f, 48, {120, 180, 255, 200});
    for (int i = 0; i < 24; i++) {
        float a = (float)i / 24.0f * 2 * 3.14159f;
        Vector3 p{center.x + cosf(a) * radius, 1.5f, center.z + sinf(a) * radius};
        DrawCube(p, 0.4f, 3.0f, 0.4f, {90, 130, 200, 255});
    }
}
