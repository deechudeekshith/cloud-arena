#include "Bot.h"

BotParams GetBotParams(BotPersonality p) {
    switch (p) {
        case BotPersonality::Aggressive:
            return BotParams{7.2f, 7.0f, 0.55f, 0.10f, 0.55f};
        case BotPersonality::Defensive:
            return BotParams{5.6f, 13.0f, 0.85f, 0.15f, 0.45f};
        case BotPersonality::Balanced:
        default:
            return BotParams{6.4f, 10.0f, 0.70f, 0.12f, 0.50f};
    }
}
