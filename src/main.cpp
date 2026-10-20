#include "Game.h"

// ---------- PHASE 1: Window + Arena ----------
int main() {
    Game game;
    InitWindow(Game::SCREEN_W, Game::SCREEN_H, "Cloud Arena");
    SetTargetFPS(60);

    game.Init();

    while (!WindowShouldClose() && !game.ShouldClose()) {
        game.Update();
        game.Draw();
    }

    CloseWindow();
    return 0;
}