#include "UI.h"

namespace UI {

bool Button(Rectangle rect, const char* text, int fontSize) {
    Vector2 m = GetMousePosition();
    bool hover = CheckCollisionPointRec(m, rect);
    Color bg = hover ? Color{70, 110, 200, 255} : Color{45, 75, 150, 255};
    Color border = hover ? SKYBLUE : DARKBLUE;
    DrawRectangleRec(rect, bg);
    DrawRectangleLinesEx(rect, 2.0f, border);
    int tw = MeasureText(text, fontSize);
    int tx = (int)(rect.x + rect.width / 2 - tw / 2);
    int ty = (int)(rect.y + rect.height / 2 - fontSize / 2 - 2);
    DrawText(text, tx, ty, fontSize, WHITE);
    return hover && IsMouseButtonPressed(MOUSE_LEFT_BUTTON);
}

void DrawCenteredText(const char* text, int y, int fontSize, Color color, int screenW) {
    int tw = MeasureText(text, fontSize);
    DrawText(text, screenW / 2 - tw / 2, y, fontSize, color);
}

} // namespace UI
