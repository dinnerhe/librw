#ifndef RWMETAL_H
#define RWMETAL_H
#ifdef RW_METAL
#ifndef GLFW_INCLUDE_NONE
#define GLFW_INCLUDE_NONE
#endif
#include <GLFW/glfw3.h>
namespace rw
{
struct EngineOpenParams {
	GLFWwindow **window;
	int width, height;
	const char *windowtitle;
};
namespace metal
{
struct Im3DVertex {
	V3d position;
	V3d normal; // librw extension
	uint8 r, g, b, a;
	float32 u, v;

	void setX(float32 x) { this->position.x = x; }
	void setY(float32 y) { this->position.y = y; }
	void setZ(float32 z) { this->position.z = z; }
	void setNormalX(float32 x) { this->normal.x = x; }
	void setNormalY(float32 y) { this->normal.y = y; }
	void setNormalZ(float32 z) { this->normal.z = z; }
	void setColor(uint8 r, uint8 g, uint8 b, uint8 a)
	{
		this->r = r;
		this->g = g;
		this->b = b;
		this->a = a;
	}
	void setU(float32 u) { this->u = u; }
	void setV(float32 v) { this->v = v; }

	float getX(void) { return this->position.x; }
	float getY(void) { return this->position.y; }
	float getZ(void) { return this->position.z; }
	float getNormalX(void) { return this->normal.x; }
	float getNormalY(void) { return this->normal.y; }
	float getNormalZ(void) { return this->normal.z; }
	RGBA getColor(void) { return makeRGBA(this->r, this->g, this->b, this->a); }
	float getU(void) { return this->u; }
	float getV(void) { return this->v; }
};
struct Im2DVertex {
	float32 x, y, z, w;
	uint8 r, g, b, a;
	float32 u, v;

	void setScreenX(float32 x) { this->x = x; }
	void setScreenY(float32 y) { this->y = y; }
	void setScreenZ(float32 z) { this->z = z; }
	// This is a bit unefficient but we have to counteract GL's divide, so multiply
	void setCameraZ(float32 z) { this->w = z; }
	void setRecipCameraZ(float32 recipz) { this->w = 1.0f / recipz; }
	void setColor(uint8 r, uint8 g, uint8 b, uint8 a)
	{
		this->r = r;
		this->g = g;
		this->b = b;
		this->a = a;
	}
	void setU(float32 u, float recipz) { this->u = u; }
	void setV(float32 v, float recipz) { this->v = v; }

	float getScreenX(void) { return this->x; }
	float getScreenY(void) { return this->y; }
	float getScreenZ(void) { return this->z; }
	float getCameraZ(void) { return this->w; }
	float getRecipCameraZ(void) { return 1.0f / this->w; }
	RGBA getColor(void) { return makeRGBA(this->r, this->g, this->b, this->a); }
	float getU(void) { return this->u; }
	float getV(void) { return this->v; }
};

extern RGBA im3dMaterialColor;
extern SurfaceProperties im3dSurfaceProps;
extern Device renderdevice;
void registerPlatformPlugins(void);
void writeNativeTexture(Texture *texture, Stream *stream);
uint32 getSizeNativeTexture(Texture *texture);
void initSkin(void);
void initMatFX(void);
void *destroyNativeData(void *object, int32, int32);
void setScissor(float x, float y, float width, float height);
void disableScissor(void);
// Waits for submitted GPU work and reports command failures.
bool32 waitIdle(void);
const char *getDeviceName(void);
} // namespace metal
} // namespace rw
#endif
#endif
