#pragma once
#include "Player.h"

struct BotParams {
    float speed;
    float preferredRange;
    float fireInterval;
    float aimNoise;
    float hitChance; // base probability per shot at close range
};

BotParams GetBotParams(BotPersonality p);
