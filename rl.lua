-- struct-by-value FFI calls (Color etc.) are not JIT-compiled: overlay only, hot path uses rlgl scalars
local ffi = require("ffi")

ffi.cdef([[
typedef struct { unsigned char r, g, b, a; } Color;
typedef struct { float x, y; } Vector2;
typedef struct { void *data; int width, height, mipmaps, format; } Image;
typedef struct { unsigned int id; int width, height, mipmaps, format; } Texture2D;

void SetConfigFlags(unsigned int flags);
void SetTraceLogLevel(int logLevel);
void InitWindow(int width, int height, const char *title);
void CloseWindow(void);
bool WindowShouldClose(void);
int GetScreenWidth(void);
int GetScreenHeight(void);
void SetTargetFPS(int fps);
int GetFPS(void);
void BeginDrawing(void);
void EndDrawing(void);
void ClearBackground(Color color);
void TakeScreenshot(const char *fileName);
double GetTime(void);

bool IsKeyPressed(int key);
bool IsKeyDown(int key);
bool IsMouseButtonPressed(int button);
bool IsMouseButtonDown(int button);
bool IsMouseButtonReleased(int button);
int GetMouseX(void);
int GetMouseY(void);
Vector2 GetMouseDelta(void);
float GetMouseWheelMove(void);

void DrawText(const char *text, int posX, int posY, int fontSize, Color color);
void DrawRectangle(int posX, int posY, int width, int height, Color color);

Image GenImageGradientRadial(int width, int height, float density, Color inner, Color outer);
Texture2D LoadTextureFromImage(Image image);
void UnloadImage(Image image);
void SetTextureFilter(Texture2D texture, int filter);
void UpdateTexture(Texture2D texture, const void *pixels);

void rlPushMatrix(void);
void rlPopMatrix(void);
void rlTranslatef(float x, float y, float z);
void rlScalef(float x, float y, float z);
void rlBegin(int mode);
void rlEnd(void);
void rlVertex2f(float x, float y);
void rlTexCoord2f(float x, float y);
void rlColor4ub(unsigned char r, unsigned char g, unsigned char b, unsigned char a);
void rlSetTexture(unsigned int id);
bool rlCheckRenderBatchLimit(int vCount);
void rlDrawRenderBatchActive(void);
]])

local ok, lib = pcall(ffi.load, "raylib")
if not ok then lib = ffi.load("/opt/homebrew/lib/libraylib.dylib") end
return lib
