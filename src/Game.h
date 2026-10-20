#pragma once
#include "raylib.h"
#include <vector>
#include <string>
#include <cmath>

enum class GameState { Menu, Playing, Paused, GameOver };

struct PlayerState {
    std::string name = "Player";
    Color color = WHITE;
    int health = 100;
    int maxHealth = 100;
    int score = 0;
    int kills = 0;
    int deaths = 0;
    bool alive = true;
    float x = 0, y = 0;
    float angle = 0;
    float respawnTimer = 0;
};

struct BotState {
    std::string name = "Bot";
    Color color = GRAY;
    int health = 100;
    int maxHealth = 100;
    float x = 0, y = 0;
    float angle = 0;
    bool alive = true;
    int kills = 0;
    int score = 0;
    float respawnTimer = 0;
};

struct ArenaState {
    float xMin = 240, xMax = 1040;
    float yMin = 140, yMax = 660;
    struct Wall { float x1, y1, x2, y2; } walls[16];
    int wallCount = 0;
    Vector3 spawnPoints[4];
};

struct GameStats {
    int matchTime = 180; // 3 minutes in seconds
    int remainingTime = 180;
    bool timerRunning = false;
    GameState state = GameState::Menu;
    int winner = -1;
};

struct Game {
    static const int SCREEN_W = 1280;
    static const int SCREEN_H = 800;
    static const int MAX_PLAYERS = 4;

    PlayerState players[MAX_PLAYERS];
    BotState bots[MAX_PLAYERS - 1];
    ArenaState arena;
    GameStats stats;
    bool showMenu = true;
    bool showControls = false;
    bool showPauseMenu = false;

    Game();
    void Init();
    void Update();
    void Draw();
    bool ShouldClose() const { return windowShouldClose; }
    GameState GetState() const { return stats.state; }
    void SetState(GameState s) { stats.state = s; }

private:
    bool windowShouldClose = false;
};