#include "Game.h"
#include <cmath>
#include <cstring>
#include <cstdio>

static float ClampF(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

static void StartMatchCommon(Game &g) {
    g.showMenu = false;
    g.showControls = false;
    g.showPauseMenu = false;
    g.stats.state = GameState::Playing;
    g.stats.matchTime = 180;
    g.stats.remainingTime = 180;
    g.stats.timerRunning = true;
    g.stats.winner = -1;
    for (int i = 0; i < Game::MAX_PLAYERS; i++) {
        g.players[i].health = 100;
        g.players[i].alive = true;
        g.players[i].kills = 0;
        g.players[i].score = 0;
        g.players[i].deaths = 0;
        g.players[i].respawnTimer = 0;
        g.players[i].x = g.arena.spawnPoints[i].x;
        g.players[i].y = g.arena.spawnPoints[i].y;
    }
    for (int i = 0; i < Game::MAX_PLAYERS - 1; i++) {
        g.bots[i].health = 100;
        g.bots[i].alive = true;
        g.bots[i].kills = 0;
        g.bots[i].score = 0;
        g.bots[i].respawnTimer = 0;
        g.bots[i].x = g.arena.spawnPoints[i + 1].x;
        g.bots[i].y = g.arena.spawnPoints[i + 1].y;
    }
}

Game::Game() {
    for (int i = 0; i < MAX_PLAYERS; i++) {
        players[i].name = (i == 0) ? "YOU" : ("BOT " + std::to_string(i));
        players[i].color = (i == 0) ? GREEN : (i == 1 ? RED : (i == 2 ? BLUE : PURPLE));
        players[i].health = 100;
        players[i].maxHealth = 100;
        players[i].alive = true;
        players[i].kills = 0;
        players[i].score = 0;
        players[i].deaths = 0;
        players[i].respawnTimer = 0;
        players[i].x = 640;
        players[i].y = 400;
    }
    for (int i = 0; i < MAX_PLAYERS - 1; i++) {
        bots[i].name = ("BOT " + std::to_string(i + 1));
        bots[i].color = (i == 0) ? RED : (i == 1 ? BLUE : PURPLE);
        bots[i].health = 100;
        bots[i].maxHealth = 100;
        bots[i].alive = true;
        bots[i].kills = 0;
        bots[i].score = 0;
        bots[i].respawnTimer = 0;
        bots[i].x = 640;
        bots[i].y = 400;
    }

    arena.xMin = 240; arena.xMax = 1040;
    arena.yMin = 140; arena.yMax = 660;
    arena.wallCount = 0;
    arena.walls[arena.wallCount++] = {240, 140, 1040, 140};
    arena.walls[arena.wallCount++] = {1040, 140, 1040, 660};
    arena.walls[arena.wallCount++] = {1040, 660, 240, 660};
    arena.walls[arena.wallCount++] = {240, 660, 240, 140};
    // center cross
    arena.walls[arena.wallCount++] = {540, 400, 740, 400};
    arena.walls[arena.wallCount++] = {640, 280, 640, 520};
    // side blocks
    arena.walls[arena.wallCount++] = {360, 300, 440, 300};
    arena.walls[arena.wallCount++] = {840, 300, 920, 300};
    arena.walls[arena.wallCount++] = {360, 500, 440, 500};
    arena.walls[arena.wallCount++] = {840, 500, 920, 500};

    arena.spawnPoints[0] = {300, 200, 0};
    arena.spawnPoints[1] = {980, 200, 0};
    arena.spawnPoints[2] = {980, 600, 0};
    arena.spawnPoints[3] = {300, 600, 0};

    players[0].x = 300; players[0].y = 200;
    for (int i = 0; i < 3; i++) { bots[i].x = arena.spawnPoints[i+1].x; bots[i].y = arena.spawnPoints[i+1].y; }

    stats.matchTime = 180;
    stats.remainingTime = 180;
    stats.timerRunning = false;
    stats.state = GameState::Menu;
    stats.winner = -1;

    showMenu = true;
    showControls = false;
    showPauseMenu = false;
}

void Game::Init() {
    SetTargetFPS(60);
    stats.remainingTime = 180;
    stats.state = GameState::Menu;
    showMenu = true;
}

void Game::Update() {
    windowShouldClose = WindowShouldClose();

    // MENU
    if (showMenu) {
        if (IsKeyPressed(KEY_ENTER) || IsKeyPressed(KEY_SPACE)) {
            StartMatchCommon(*this);
        }
        if (IsKeyPressed(KEY_C)) showControls = true;
        if (IsKeyPressed(KEY_Q)) windowShouldClose = true;
        return;
    }
    if (showControls) {
        if (IsKeyPressed(KEY_ESCAPE) || IsKeyPressed(KEY_ENTER) || IsKeyPressed(KEY_C))
            showControls = false;
        return;
    }

    // GAMEOVER
    if (stats.state == GameState::GameOver) {
        if (IsKeyPressed(KEY_ENTER) || IsKeyPressed(KEY_SPACE)) {
            StartMatchCommon(*this);
        }
        if (IsKeyPressed(KEY_ESCAPE) || IsKeyPressed(KEY_M)) {
            showMenu = true;
            stats.state = GameState::Menu;
        }
        return;
    }

    // PAUSED
    if (stats.state == GameState::Paused) {
        if (IsKeyPressed(KEY_ESCAPE) || IsKeyPressed(KEY_P)) stats.state = GameState::Playing;
        if (IsKeyPressed(KEY_R)) StartMatchCommon(*this);
        if (IsKeyPressed(KEY_M)) { showMenu = true; stats.state = GameState::Menu; }
        return;
    }

    // PLAYING
    if (stats.state != GameState::Playing) return;

    if (IsKeyPressed(KEY_ESCAPE) || IsKeyPressed(KEY_P)) {
        stats.state = GameState::Paused;
        return;
    }

    float dt = GetFrameTime();
    if (dt > 0.05f) dt = 0.05f;
    if (dt <= 0) dt = 1.0f/60.0f;

    // 3-minute countdown, robust across restarts
    static float timerF = 180.0f;
    static int lastSeenRemaining = 180;
    if (stats.remainingTime >= 180 && lastSeenRemaining < 180) timerF = 180.0f; // fresh match
    if (stats.remainingTime >= 180 && timerF < 179.0f) timerF = 180.0f;
    timerF -= dt;
    if (timerF < 0) timerF = 0;
    stats.remainingTime = (int)ceilf(timerF);
    lastSeenRemaining = stats.remainingTime;
    if (stats.remainingTime <= 0) {
        stats.remainingTime = 0;
        stats.state = GameState::GameOver;
        timerF = -1;
        int best = players[0].score;
        int win = 0;
        for (int i = 0; i < 3; i++) {
            if (bots[i].score > best) { best = bots[i].score; win = i+1; }
        }
        stats.winner = win;
        return;
    }
    // keep timerF reset detection for next match
    if (stats.remainingTime == 180) timerF = 180.0f;

    // HUMAN
    PlayerState &me = players[0];
    if (!me.alive) {
        me.respawnTimer -= dt;
        if (me.respawnTimer <= 0) {
            me.alive = true;
            me.health = 100;
            me.x = arena.spawnPoints[0].x;
            me.y = arena.spawnPoints[0].y;
        }
    } else {
        float speed = 340.0f;
        float mx = 0, my = 0;
        if (IsKeyDown(KEY_W) || IsKeyDown(KEY_UP)) my -= 1;
        if (IsKeyDown(KEY_S) || IsKeyDown(KEY_DOWN)) my += 1;
        if (IsKeyDown(KEY_A) || IsKeyDown(KEY_LEFT)) mx -= 1;
        if (IsKeyDown(KEY_D) || IsKeyDown(KEY_RIGHT)) mx += 1;
        if (mx != 0 || my != 0) {
            float l = sqrtf(mx*mx+my*my);
            mx/=l; my/=l;
            me.x += mx*speed*dt;
            me.y += my*speed*dt;
        }
        me.x = ClampF(me.x, arena.xMin+20, arena.xMax-20);
        me.y = ClampF(me.y, arena.yMin+20, arena.yMax-20);

        Vector2 mp = GetMousePosition();
        me.angle = atan2f(mp.y - me.y, mp.x - me.x);

        if (IsMouseButtonPressed(MOUSE_LEFT_BUTTON) || IsKeyPressed(KEY_SPACE)) {
            int bestBi = -1;
            float bestD = 1e9f;
            for (int i = 0; i < 3; i++) {
                if (!bots[i].alive) continue;
                float dx = bots[i].x - me.x, dy = bots[i].y - me.y;
                float d = sqrtf(dx*dx+dy*dy);
                if (d < bestD) { bestD = d; bestBi = i; }
            }
            if (bestBi >= 0 && bestD < 650.0f) {
                bots[bestBi].health -= 20;
                if (bots[bestBi].health <= 0) {
                    bots[bestBi].health = 0;
                    bots[bestBi].alive = false;
                    bots[bestBi].respawnTimer = 3.0f;
                    me.kills++;
                    me.score++;
                }
            }
        }
    }

    // BOTS
    for (int i = 0; i < 3; i++) {
        BotState &b = bots[i];
        if (!b.alive) {
            b.respawnTimer -= dt;
            if (b.respawnTimer <= 0) {
                b.alive = true;
                b.health = 100;
                b.x = arena.spawnPoints[i+1].x;
                b.y = arena.spawnPoints[i+1].y;
            }
            continue;
        }
        // chase human
        float dx = me.x - b.x, dy = me.y - b.y;
        float dist = sqrtf(dx*dx+dy*dy);
        float spd = 200.0f + i*30.0f; // different personalities
        if (me.alive && dist > 180.0f) {
            if (dist > 1) { dx/=dist; dy/=dist; }
            b.x += dx*spd*dt;
            b.y += dy*spd*dt;
            b.angle = atan2f(dy, dx);
        } else if (me.alive) {
            // strafe around
            float a = atan2f(dy, dx) + (i==0? 1.0f : -1.0f)*dt*2.0f;
            b.angle = atan2f(me.y-b.y, me.x-b.x);
            b.x += cosf(a+1.57f)*spd*0.6f*dt;
            b.y += sinf(a+1.57f)*spd*0.6f*dt;
            // shoot
            float shootChance = (i==0? 0.025f : (i==1? 0.015f : 0.008f));
            if (dist < 480.0f && GetRandomValue(0,1000)/1000.0f < shootChance) {
                me.health -= 20;
                b.kills++; // shots landed tracker (approx)
                if (me.health <= 0) {
                    me.health = 0;
                    me.alive = false;
                    me.deaths++;
                    me.respawnTimer = 3.0f;
                    b.score++;
                }
            }
        } else {
            // wander to center
            float cx = 640 - b.x, cy = 400 - b.y;
            float d = sqrtf(cx*cx+cy*cy);
            if (d > 5) { b.x += cx/d*spd*0.5f*dt; b.y += cy/d*spd*0.5f*dt; }
        }
        b.x = ClampF(b.x, arena.xMin+15, arena.xMax-15);
        b.y = ClampF(b.y, arena.yMin+15, arena.yMax-15);
    }
}

void Game::Draw() {
    BeginDrawing();
    ClearBackground({20, 30, 40, 255});

    if (showMenu) {
        DrawText("CLOUD ARENA", SCREEN_W/2-190, 100, 64, SKYBLUE);
        DrawText("2D TOP-DOWN - 1 YOU vs 3 BOTS - OFFLINE PROTOTYPE", SCREEN_W/2-280, 170, 20, LIGHTGRAY);
        DrawText("Press ENTER to Start", SCREEN_W/2-140, 250, 28, WHITE);
        DrawText("Press C for Controls", SCREEN_W/2-140, 290, 24, GRAY);
        DrawText("WASD move | Mouse aim | Click shoot | ESC pause", SCREEN_W/2-250, 330, 20, GRAY);
        DrawText("3-minute match, 20 dmg/hit, respawn 3s", SCREEN_W/2-210, 360, 20, GRAY);
        for (int i = 0; i < 4; i++) {
            DrawCircle((int)arena.spawnPoints[i].x, (int)arena.spawnPoints[i].y, 14, i==0?GREEN:RED);
        }
        // mini arena preview
        DrawRectangleLines((int)arena.xMin, (int)arena.yMin, (int)(arena.xMax-arena.xMin), (int)(arena.yMax-arena.yMin), DARKGRAY);
        EndDrawing();
        return;
    }
    if (showControls) {
        DrawText("CONTROLS", SCREEN_W/2-110, 100, 44, SKYBLUE);
        DrawText("WASD / Arrows - Move", SCREEN_W/2-150, 200, 26, WHITE);
        DrawText("Mouse - Aim", SCREEN_W/2-150, 245, 26, WHITE);
        DrawText("Left Click / Space - Shoot", SCREEN_W/2-150, 290, 26, WHITE);
        DrawText("ESC / P - Pause", SCREEN_W/2-150, 335, 26, WHITE);
        DrawText("R - Restart (when paused)", SCREEN_W/2-150, 380, 26, WHITE);
        DrawText("Press ESC or ENTER to go Back", SCREEN_W/2-190, 460, 22, YELLOW);
        EndDrawing();
        return;
    }

    if (stats.state == GameState::GameOver) {
        DrawText("MATCH COMPLETE", SCREEN_W/2-200, 90, 52, SKYBLUE);
        const char* wname = "YOU";
        int wscore = players[0].score;
        if (stats.winner == 1) { wname = "BOT 1"; wscore = bots[0].score; }
        else if (stats.winner == 2) { wname = "BOT 2"; wscore = bots[1].score; }
        else if (stats.winner == 3) { wname = "BOT 3"; wscore = bots[2].score; }
        char wb[64]; snprintf(wb, sizeof(wb), "WINNER: %s  SCORE: %d", wname, wscore);
        DrawText(wb, SCREEN_W/2-200, 170, 30, YELLOW);
        DrawText("PLAYER   KILLS   DEATHS   SCORE", SCREEN_W/2-200, 230, 22, GRAY);
        char line[96];
        snprintf(line, sizeof(line), "YOU      %d       %d        %d", players[0].kills, players[0].deaths, players[0].score);
        DrawText(line, SCREEN_W/2-200, 270, 22, GREEN);
        for (int i = 0; i < 3; i++) {
            snprintf(line, sizeof(line), "BOT %d     %d       %d        %d", i+1, players[0].kills*0 + (bots[i].score), 0, bots[i].score);
            // deaths for bots not tracked separately; show score as kills
            DrawText(line, SCREEN_W/2-200, 300+i*30, 22, bots[i].color);
        }
        DrawText("Press ENTER to Play Again", SCREEN_W/2-170, 440, 26, WHITE);
        DrawText("Press ESC for Main Menu", SCREEN_W/2-170, 480, 26, WHITE);
        EndDrawing();
        return;
    }

    // Playing + Paused share world draw
    // floor
    DrawRectangle((int)arena.xMin, (int)arena.yMin, (int)(arena.xMax-arena.xMin), (int)(arena.yMax-arena.yMin), {32, 46, 62, 255});
    DrawRectangleLines((int)arena.xMin, (int)arena.yMin, (int)(arena.xMax-arena.xMin), (int)(arena.yMax-arena.yMin), WHITE);
    for (int w = 0; w < arena.wallCount; w++) {
        DrawLineEx({arena.walls[w].x1, arena.walls[w].y1}, {arena.walls[w].x2, arena.walls[w].y2}, 5, GRAY);
    }
    // center mark
    DrawCircle(640, 400, 6, DARKGRAY);

    // bots
    for (int i = 0; i < 3; i++) {
        BotState &b = bots[i];
        if (!b.alive) {
            DrawCircle((int)b.x, (int)b.y, 15, DARKGRAY);
            DrawText("RESPAWN...", (int)b.x-35, (int)b.y-40, 12, GRAY);
            continue;
        }
        DrawCircle((int)b.x, (int)b.y, 16, b.color);
        DrawCircleLines((int)b.x, (int)b.y, 16, WHITE);
        float ax = b.x + cosf(b.angle)*26, ay = b.y + sinf(b.angle)*26;
        DrawLineEx({b.x, b.y}, {ax, ay}, 3, WHITE);
        DrawRectangle((int)b.x-18, (int)b.y-32, 36, 6, BLACK);
        float f = ClampF(b.health/100.0f, 0, 1);
        DrawRectangle((int)b.x-18, (int)b.y-32, (int)(36*f), 6, f>0.5?GREEN:(f>0.25?ORANGE:RED));
        DrawText(b.name.c_str(), (int)b.x-18, (int)b.y+20, 13, WHITE);
    }

    // human
    PlayerState &me = players[0];
    if (!me.alive) {
        DrawCircle((int)me.x, (int)me.y, 19, DARKGRAY);
        char rb[32]; snprintf(rb, sizeof(rb), "RESPAWN %.1fs", me.respawnTimer);
        DrawText(rb, (int)me.x-40, (int)me.y-44, 14, YELLOW);
    } else {
        DrawCircle((int)me.x, (int)me.y, 19, me.color);
        DrawCircleLines((int)me.x, (int)me.y, 19, WHITE);
        float ax = me.x + cosf(me.angle)*34, ay = me.y + sinf(me.angle)*34;
        DrawLineEx({me.x, me.y}, {ax, ay}, 3, YELLOW);
        DrawRectangle((int)me.x-28, (int)me.y-40, 56, 8, BLACK);
        float f = ClampF(me.health/100.0f, 0, 1);
        DrawRectangle((int)me.x-28, (int)me.y-40, (int)(56*f), 8, f>0.5?GREEN:(f>0.25?ORANGE:RED));
        DrawText("YOU", (int)me.x-12, (int)me.y+24, 14, WHITE);
    }

    // HUD top bar
    DrawRectangle(0, 0, SCREEN_W, 96, {12, 16, 26, 220});
    char tbuf[16]; snprintf(tbuf, sizeof(tbuf), "%02d:%02d", stats.remainingTime/60, stats.remainingTime%60);
    DrawText("CLOUD ARENA", 20, 8, 22, SKYBLUE);
    DrawText(tbuf, SCREEN_W/2-40, 8, 34, stats.remainingTime<30?RED:WHITE);
    char hbuf[32]; snprintf(hbuf, sizeof(hbuf), "HP %d/100  SCORE %d  K %d D %d", me.alive?me.health:0, me.score, me.kills, me.deaths);
    DrawText(hbuf, 20, 58, 20, WHITE);
    char sb[64]; snprintf(sb, sizeof(sb), "YOU %d  B1 %d  B2 %d  B3 %d", me.score, bots[0].score, bots[1].score, bots[2].score);
    DrawText(sb, SCREEN_W-360, 58, 20, LIGHTGRAY);

    DrawText("WASD move | Mouse aim | Click shoot | ESC pause", SCREEN_W/2-220, SCREEN_H-28, 16, GRAY);

    if (stats.state == GameState::Paused) {
        DrawRectangle(0, 0, SCREEN_W, SCREEN_H, {0, 0, 0, 150});
        DrawText("PAUSED", SCREEN_W/2-90, 220, 52, WHITE);
        DrawText("ESC/P - Resume", SCREEN_W/2-110, 300, 24, WHITE);
        DrawText("R - Restart match", SCREEN_W/2-110, 335, 24, WHITE);
        DrawText("M - Main menu", SCREEN_W/2-110, 370, 24, WHITE);
    }

    EndDrawing();
}
