#ifndef RWMETALIMPL_H
#define RWMETALIMPL_H
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Cocoa/Cocoa.h>
#include <simd/simd.h>
#include <map>
#include <string>
#include <vector>
#include <atomic>
#include <dispatch/dispatch.h>

namespace rw
{
namespace metal
{
static const int MaxLights = 16;
struct Vertex {
	float position[3], normal[3];
	uint8 color[4];
	float uv[2], weights[4];
	uint8 bones[4];
};
struct Uniforms {
	simd_float4x4 world, view, projection, envMatrix;
	simd_float4 material, surface, ambient, fogColor;
	simd_float4 fog, alpha, window, envParams, envColor, textureRegion;
	simd_uint4 flags;
	simd_float4 lightParams[MaxLights], lightPosition[MaxLights];
	simd_float4 lightDirection[MaxLights], lightColor[MaxLights];
};
struct RasterData {
	id<MTLTexture> texture, multisample;
	std::vector<uint8> locked;
	int level = -1;
	int mode = 0;
	bool hasAlpha = false;
};
struct MeshData {
	uint32 offset, count;
	Material *material;
	bool vertexAlpha;
};
struct GeometryData : rw::InstanceDataHeader {
	uint32 serial;
	id<MTLBuffer> vertices, indices;
	std::vector<MeshData> meshes;
	MTLPrimitiveType primitive;
};
struct DisplayMode {
	GLFWvidmode mode;
	uint32 flags;
};
struct Context {
	id<MTLDevice> device;
	id<MTLCommandQueue> queue;
	id<MTLLibrary> library;
	id<MTLCommandBuffer> command, lastCommand;
	id<MTLRenderCommandEncoder> encoder;
	CAMetalLayer *layer;
	GLFWwindow *window = nullptr;
	GLFWwindow **windowOut = nullptr;
	EngineOpenParams params;
	GLFWmonitor *monitor = nullptr;
	std::vector<DisplayMode> modes;
	int currentMode = 0;
	id<MTLTexture> backColor, backDepth, backMultisample, color, depth, renderColor;
	Camera *camera = nullptr;
	Rect viewport = {};
	Uniforms uniforms = {};
	uintptr states[GSALPHATESTREF + 1] = {};
	std::map<uint64, id<MTLRenderPipelineState>> pipelines;
	std::map<std::vector<uint32>, id<MTLDepthStencilState>> depths;
	std::map<uint32, id<MTLSamplerState>> samplers;
	id<MTLTexture> white;
	id<MTLBuffer> identityBones;
	std::vector<Vertex> immediate;
	Matrix immediateWorld;
	uint32 immediateFlags = 0;
	bool skinRegistered = false, matfxRegistered = false;
	std::atomic<bool> failed{false};
	bool clipEnabled = false;
	float clip[4] = {};
	uint32 samples = 1;
	std::string name;
	dispatch_semaphore_t frameSlots;
};
extern Context ctx;
extern int32 nativeRasterOffset;
RasterData *rasterData(Raster *raster);
id<MTLTexture> makeTexture(int width, int height, MTLPixelFormat format, bool mipmaps,
						   bool renderTarget);
id<MTLTexture> makeMultisampleTexture(int width, int height, MTLPixelFormat format);
void ensureCommand(void);
void endPass(void);
bool submit(bool wait);
void ensurePass(Camera *camera);
Raster *rasterCreate(Raster *);
uint8 *rasterLock(Raster *, int32 level, int32 mode);
void rasterUnlock(Raster *, int32 level);
int32 rasterNumLevels(Raster *);
bool32 imageFindRasterFormat(Image *, int32 type, int32 *, int32 *, int32 *, int32 *);
bool32 rasterFromImage(Raster *, Image *);
Image *rasterToImage(Raster *);
void registerRaster(void);
void reportError(const char *message);
} // namespace metal
} // namespace rw
#endif
