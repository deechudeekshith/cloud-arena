#pragma once
#include "raylib.h"
#include <vector>

// 3D arena: circular ground, boundary ring, solid boxes (buildings/cover).
struct SolidBox {
    Vector3 center{0, 0, 0};
    Vector3 size{1, 1, 1}; // full extents
    Color color = GRAY;
    Color edge = WHITE;
    bool crate = false;    // waist-high cover look
};

struct GroundPatch {
    Vector3 pos{0, 0, 0};
    float w = 4, d = 4;    // rect size, or radius if circle
    Color color = GREEN;
    bool circle = false;
};

struct Decor3D {
    Vector3 pos{0, 0, 0};
    float size = 1.0f;
    int kind = 0; // 0 tree, 1 rock, 2 bush
    float phase = 0.0f;
};

struct Arena {
    Vector3 center{0, 0, 0};
    float radius = 32.0f;
    std::vector<SolidBox> boxes;
    std::vector<Vector3> spawns; // 8 spawns (y=0 feet)
    std::vector<GroundPatch> ground;
    std::vector<Decor3D> decor;

    void Init();
    // XZ circle collision vs boxes + boundary ring
    bool CollidesXZ(Vector3 p, float r) const;
    // Resolve movement axis-separated; returns corrected position
    Vector3 MoveCollide(Vector3 p, Vector3 delta, float r) const;
    bool InsideArena(Vector3 p, float margin) const;
    // Segment blocked by boxes (for AI line of sight), eye height considered by caller
    bool SegmentBlocked(Vector3 a, Vector3 b) const;
    // Ray vs boxes, returns nearest distance or -1
    float RayHitBox(Ray ray, Vector3* hitPoint) const;
    Vector3 GetSpawn(int i) const;
    float GetYawToCenter(Vector3 p) const;

    void DrawGround() const;
    void DrawSolids() const;
    void DrawDecor(float time) const;
    void DrawBoundary() const;
};
