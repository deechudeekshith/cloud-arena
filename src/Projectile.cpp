#include "Projectile.h"

void Projectile::Update(float dt) {
    if (!active) return;
    life -= dt;
    if (life <= 0) active = false;
}

void Projectile::Draw() const {
    if (!active) return;
    DrawLine3D(start, end, color);
    DrawSphere(end, 0.07f, color);
}
