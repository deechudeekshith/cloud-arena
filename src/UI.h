#pragma once
#include "raylib.h"

// Small UI helpers (buttons, centered text). Keeps Game.cpp clean.
namespace UI {
bool Button(Rectangle rect, const char* text, int fontSize);
void DrawCenteredText(const char* text, int y, int fontSize, Color color, int screenW);
}
