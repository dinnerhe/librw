#include "../../rw.h"
#include "metalimpl.h"
#include "metal_shaders.h"
#define GLFW_EXPOSE_NATIVE_COCOA
#include <GLFW/glfw3native.h>
#include <algorithm>
#include <cstring>
#include <cmath>

namespace rw
{
namespace metal
{
static_assert(sizeof(Vertex) == 56, "MSL vertex layout");
static_assert(sizeof(Uniforms) == 1456, "MSL uniform layout");
Context ctx;
RGBA im3dMaterialColor = {255, 255, 255, 255};
SurfaceProperties im3dSurfaceProps = {1, 1, 1};
static rw::ObjPipeline *defaultPipeline, *skinPipeline, *matfxPipeline;
static simd_float4 color(const RGBA &c)
{
	return simd_make_float4(c.red, c.green, c.blue, c.alpha) / 255.0f;
}
static simd_float4x4 matrix(Matrix *m)
{
	RawMatrix raw;
	convMatrix(&raw, m);
	simd_float4x4 r;
	memcpy(&r, &raw, 64);
	return r;
}
void reportError(const char *message)
{
	fprintf(stderr, "librw Metal: %s\n", message);
	ctx.failed = true;
}
const char *getDeviceName(void)
{
	return ctx.name.c_str();
}

void ensureCommand(void)
{
	if (!ctx.command && ctx.queue) {
		dispatch_semaphore_wait(ctx.frameSlots, DISPATCH_TIME_FOREVER);
		ctx.command = [ctx.queue commandBuffer];
		ctx.command.label = @"librw frame";
	}
}
void endPass(void)
{
	if (ctx.encoder) {
		[ctx.encoder endEncoding];
		ctx.encoder = nil;
	}
}
BufferSlice allocateUpload(size_t size)
{
	ensureCommand();
	size_t alignedSize = (size + 255) & ~size_t(255);
	if (!ctx.uploadBuffer || ctx.uploadOffset + alignedSize > ctx.uploadBuffer.length) {
		ctx.uploadBuffer = [ctx.device newBufferWithLength:std::max(size_t(1024 * 1024), alignedSize)
													 options:MTLResourceStorageModeShared];
		ctx.uploadBuffer.label = @"librw transient uploads";
		ctx.uploadOffset = 0;
	}
	if (!ctx.uploadBuffer) {
		reportError("Could not allocate transient upload buffer");
		return {nil, 0};
	}
	BufferSlice result = {ctx.uploadBuffer, ctx.uploadOffset};
	ctx.uploadOffset += alignedSize;
	return result;
}
static BufferSlice upload(const void *data, size_t size)
{
	BufferSlice result = allocateUpload(size);
	if (result.buffer)
		memcpy((uint8 *)result.buffer.contents + result.offset, data, size);
	return result;
}
bool submit(bool wait)
{
	@autoreleasepool {
		endPass();
		if (ctx.command) {
			id<MTLCommandBuffer> command = ctx.command;
			dispatch_semaphore_t slots = ctx.frameSlots;
			[command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
			  if (completed.status == MTLCommandBufferStatusError)
				  reportError(completed.error.localizedDescription.UTF8String);
			  dispatch_semaphore_signal(slots);
			}];
			ctx.lastCommand = command;
			ctx.command = nil;
			// Encoded draws and blits retain their buffers. A new command gets fresh
			// storage so CPU uploads never overwrite an earlier frame's data.
			ctx.uploadBuffer = nil;
			ctx.uploadOffset = 0;
			[command commit];
			if (wait)
				[command waitUntilCompleted];
		}
		return !ctx.failed;
	}
}
bool32 waitIdle(void)
{
	@autoreleasepool {
		submit(true);
		[ctx.lastCommand waitUntilCompleted];
		return !ctx.failed;
	}
}

static void targets(Camera *camera)
{
	Raster *raster = camera->frameBuffer, *root = raster->parent;
	if (root->type == Raster::CAMERA) {
		int width, height;
		glfwGetFramebufferSize(ctx.window, &width, &height);
		width = std::max(width, 1);
		height = std::max(height, 1);
		if (!ctx.backColor || ctx.backColor.width != (NSUInteger)width ||
			ctx.backColor.height != (NSUInteger)height) {
			endPass();
			ctx.backColor = makeTexture(width, height, MTLPixelFormatBGRA8Unorm, false, true);
			ctx.backDepth =
				makeMultisampleTexture(width, height, MTLPixelFormatDepth32Float_Stencil8);
			ctx.backMultisample =
				ctx.samples > 1 ? makeMultisampleTexture(width, height, MTLPixelFormatBGRA8Unorm)
								: nil;
			ctx.layer.drawableSize = CGSizeMake(width, height);
		}
		ctx.color = ctx.backColor;
		ctx.renderColor = ctx.samples > 1 ? ctx.backMultisample : ctx.color;
		ctx.depth = camera->zBuffer ? ctx.backDepth : nil;
		// Camera rasters use logical pixels; scale subrasters on Retina displays.
		float sx = (float)width / std::max(root->width, 1),
			  sy = (float)height / std::max(root->height, 1);
		ctx.viewport = {int(raster->offsetX * sx), int(raster->offsetY * sy),
						raster == root ? width : int(raster->width * sx),
						raster == root ? height : int(raster->height * sy)};
	} else {
		RasterData *data = rasterData(root);
		ctx.color = data->texture;
		if (ctx.samples > 1 && !data->multisample)
			data->multisample =
				makeMultisampleTexture(root->width, root->height, ctx.color.pixelFormat);
		ctx.renderColor = ctx.samples > 1 ? data->multisample : ctx.color;
		ctx.depth = camera->zBuffer ? rasterData(camera->zBuffer->parent)->texture : nil;
		ctx.viewport = {raster->offsetX, raster->offsetY, raster->width, raster->height};
	}
}
void ensurePass(Camera *camera)
{
	if (!camera || !ctx.device)
		return;
	if (ctx.encoder && ctx.camera == camera)
		return;
	endPass();
	targets(camera);
	ctx.camera = camera;
	if (!ctx.color)
		return;
	ensureCommand();
	MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
	pass.colorAttachments[0].texture = ctx.renderColor;
	if (ctx.samples > 1)
		pass.colorAttachments[0].resolveTexture = ctx.color;
	pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
	pass.colorAttachments[0].storeAction =
		ctx.samples > 1 ? MTLStoreActionStoreAndMultisampleResolve : MTLStoreActionStore;
	if (ctx.depth) {
		pass.depthAttachment.texture = ctx.depth;
		pass.depthAttachment.loadAction = MTLLoadActionLoad;
		pass.depthAttachment.storeAction = MTLStoreActionStore;
		pass.stencilAttachment.texture = ctx.depth;
		pass.stencilAttachment.loadAction = MTLLoadActionLoad;
		pass.stencilAttachment.storeAction = MTLStoreActionStore;
	}
	ctx.encoder = [ctx.command renderCommandEncoderWithDescriptor:pass];
	ctx.encoder.label = @"librw camera";
}
static void beginUpdate(Camera *camera)
{
	@autoreleasepool {
		Matrix inv;
		Matrix::invert(&inv, camera->getFrame()->getLTM());
		RawMatrix view;
		convMatrix(&view, &inv);
		view.right.x = -view.right.x;
		view.up.x = -view.up.x;
		view.at.x = -view.at.x;
		view.pos.x = -view.pos.x;
		memcpy(&camera->devView, &view, 64);
		memcpy(&ctx.uniforms.view, &view, 64);
		float n = camera->nearPlane, f = camera->farPlane;
		float wx = 1.0f / camera->viewWindow.x, wy = 1.0f / camera->viewWindow.y;
		simd_float4x4 p = {};
		p.columns[0].x = wx;
		p.columns[1].y = wy;
		p.columns[2].x = camera->viewOffset.x * wx;
		p.columns[2].y = camera->viewOffset.y * wy;
		p.columns[3].x = -p.columns[2].x;
		p.columns[3].y = -p.columns[2].y;
		// Metal clip-space depth is [0,1]. librw cameras look along positive Z.
		if (camera->projection == Camera::PERSPECTIVE) {
			p.columns[2].z = f / (f - n);
			p.columns[2].w = 1;
			p.columns[3].z = -n * f / (f - n);
		} else {
			p.columns[2].z = 1 / (f - n);
			p.columns[3].z = -n / (f - n);
			p.columns[3].w = 1;
		}
		ctx.uniforms.projection = p;
		memcpy(&camera->devProj, &p, 64);
		ctx.uniforms.fog = simd_make_float4(camera->fogPlane, f, ctx.states[FOGENABLE], 0);
		ctx.uniforms.window =
			simd_make_float4(camera->frameBuffer->width, camera->frameBuffer->height, 0, 0);
		ensurePass(camera);
	}
}
static void endUpdate(Camera *)
{
	endPass();
}
static id<MTLRenderPipelineState> pipeline(bool alpha, uint32 clearFlags = 0);
static void clearCamera(Camera *camera, RGBA *c, uint32 flags)
{
	@autoreleasepool {
		endPass();
		targets(camera);
		ctx.camera = camera;
		if (camera->frameBuffer != camera->frameBuffer->parent) {
			// Attachment clears cover the whole texture; clear subrasters with a clipped draw.
			ensurePass(camera);
			Rect r = ctx.viewport;
			[ctx.encoder setViewport:(MTLViewport){double(r.x), double(r.y), double(r.w),
												   double(r.h), 0, 1}];
			[ctx.encoder setScissorRect:(MTLScissorRect){NSUInteger(r.x), NSUInteger(r.y),
														 NSUInteger(r.w), NSUInteger(r.h)}];
			[ctx.encoder setRenderPipelineState:pipeline(false, flags)];
			MTLDepthStencilDescriptor *ds = [[MTLDepthStencilDescriptor alloc] init];
			ds.depthCompareFunction = MTLCompareFunctionAlways;
			ds.depthWriteEnabled = ctx.depth && (flags & Camera::CLEARZ) != 0;
			if (ctx.depth && (flags & Camera::CLEARSTENCIL)) {
				MTLStencilDescriptor *st = [[MTLStencilDescriptor alloc] init];
				st.stencilCompareFunction = MTLCompareFunctionAlways;
				st.depthStencilPassOperation = MTLStencilOperationReplace;
				st.readMask = st.writeMask = 0xFF;
				ds.frontFaceStencil = ds.backFaceStencil = st;
			}
			[ctx.encoder setDepthStencilState:[ctx.device newDepthStencilStateWithDescriptor:ds]];
			[ctx.encoder setStencilReferenceValue:0];
			[ctx.encoder setCullMode:MTLCullModeNone];
			simd_float4 clearColor = color(*c);
			[ctx.encoder setVertexBytes:&clearColor length:16 atIndex:1];
			[ctx.encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
			return;
		}
		ensureCommand();
		MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
		pass.colorAttachments[0].texture = ctx.renderColor;
		if (ctx.samples > 1)
			pass.colorAttachments[0].resolveTexture = ctx.color;
		pass.colorAttachments[0].loadAction =
			flags & Camera::CLEARIMAGE ? MTLLoadActionClear : MTLLoadActionLoad;
		pass.colorAttachments[0].clearColor =
			MTLClearColorMake(c->red / 255.0, c->green / 255.0, c->blue / 255.0, c->alpha / 255.0);
		pass.colorAttachments[0].storeAction =
			ctx.samples > 1 ? MTLStoreActionStoreAndMultisampleResolve : MTLStoreActionStore;
		if (ctx.depth) {
			pass.depthAttachment.texture = ctx.depth;
			pass.depthAttachment.loadAction =
				flags & Camera::CLEARZ ? MTLLoadActionClear : MTLLoadActionLoad;
			pass.depthAttachment.clearDepth = 1;
			pass.depthAttachment.storeAction = MTLStoreActionStore;
			pass.stencilAttachment.texture = ctx.depth;
			pass.stencilAttachment.loadAction =
				flags & Camera::CLEARSTENCIL ? MTLLoadActionClear : MTLLoadActionLoad;
			pass.stencilAttachment.clearStencil = 0;
			pass.stencilAttachment.storeAction = MTLStoreActionStore;
		}
		ctx.encoder = [ctx.command renderCommandEncoderWithDescriptor:pass];
	}
}
static void showRaster(Raster *, uint32 flags)
{
	@autoreleasepool {
		endPass();
		if (!ctx.backColor) {
			submit(false);
			return;
		}
		ctx.layer.displaySyncEnabled = (flags & Raster::FLIPWAITVSYNCH) != 0;
		id<CAMetalDrawable> drawable = [ctx.layer nextDrawable];
		if (!drawable) {
			submit(false);
			return;
		}
		ensureCommand();
		id<MTLBlitCommandEncoder> blit = [ctx.command blitCommandEncoder];
		[blit copyFromTexture:ctx.backColor
				  sourceSlice:0
				  sourceLevel:0
				 sourceOrigin:MTLOriginMake(0, 0, 0)
				   sourceSize:MTLSizeMake(std::min(ctx.backColor.width, drawable.texture.width),
										  std::min(ctx.backColor.height, drawable.texture.height),
										  1)
					toTexture:drawable.texture
			 destinationSlice:0
			 destinationLevel:0
			destinationOrigin:MTLOriginMake(0, 0, 0)];
		[blit endEncoding];
		[ctx.command presentDrawable:drawable];
		submit(false);
	}
}
static void setRenderState(int32 state, void *value)
{
	if (state >= 0 && state <= GSALPHATESTREF) {
		ctx.states[state] = (uintptr)value;
		if (state == TEXTUREADDRESS)
			ctx.states[TEXTUREADDRESSU] = ctx.states[TEXTUREADDRESSV] = (uintptr)value;
	}
}
static void *getRenderState(int32 state)
{
	if (state == TEXTUREADDRESS)
		return ctx.states[TEXTUREADDRESSU] == ctx.states[TEXTUREADDRESSV]
				   ? (void *)ctx.states[TEXTUREADDRESSU]
				   : nullptr;
	return state >= 0 && state <= GSALPHATESTREF ? (void *)ctx.states[state] : nullptr;
}
void setScissor(float x, float y, float w, float h)
{
	ctx.clipEnabled = true;
	ctx.clip[0] = x;
	ctx.clip[1] = y;
	ctx.clip[2] = w;
	ctx.clip[3] = h;
}
void disableScissor(void)
{
	ctx.clipEnabled = false;
}

static MTLBlendFactor blend(int value)
{
	static MTLBlendFactor table[] = {MTLBlendFactorZero,
									 MTLBlendFactorZero,
									 MTLBlendFactorOne,
									 MTLBlendFactorSourceColor,
									 MTLBlendFactorOneMinusSourceColor,
									 MTLBlendFactorSourceAlpha,
									 MTLBlendFactorOneMinusSourceAlpha,
									 MTLBlendFactorDestinationAlpha,
									 MTLBlendFactorOneMinusDestinationAlpha,
									 MTLBlendFactorDestinationColor,
									 MTLBlendFactorOneMinusDestinationColor,
									 MTLBlendFactorSourceAlphaSaturated};
	return table[std::max(0, std::min(value, 11))];
}
static MTLStencilOperation stencil(int value)
{
	static MTLStencilOperation table[] = {
		MTLStencilOperationKeep,		   MTLStencilOperationKeep,
		MTLStencilOperationZero,		   MTLStencilOperationReplace,
		MTLStencilOperationIncrementClamp, MTLStencilOperationDecrementClamp,
		MTLStencilOperationInvert,		   MTLStencilOperationIncrementWrap,
		MTLStencilOperationDecrementWrap};
	return table[std::max(0, std::min(value, 8))];
}
static MTLCompareFunction compare(int value)
{
	static MTLCompareFunction table[] = {
		MTLCompareFunctionAlways,	MTLCompareFunctionNever,		MTLCompareFunctionLess,
		MTLCompareFunctionEqual,	MTLCompareFunctionLessEqual,	MTLCompareFunctionGreater,
		MTLCompareFunctionNotEqual, MTLCompareFunctionGreaterEqual, MTLCompareFunctionAlways};
	return table[std::max(0, std::min(value, 8))];
}
static id<MTLRenderPipelineState> pipeline(bool alpha, uint32 clearFlags)
{
	uint64 key = uint64(ctx.color.pixelFormat) | (uint64(ctx.depth != nil) << 12) |
				 (uint64(alpha) << 13) | (uint64(ctx.states[SRCBLEND]) << 14) |
				 (uint64(ctx.states[DESTBLEND]) << 18) | (uint64(ctx.samples) << 22) |
				 (uint64(clearFlags) << 28);
	auto it = ctx.pipelines.find(key);
	if (it != ctx.pipelines.end())
		return it->second;
	MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
	desc.rasterSampleCount = ctx.samples;
	desc.vertexFunction =
		[ctx.library newFunctionWithName:clearFlags ? @"clear_vertex" : @"rw_vertex"];
	desc.fragmentFunction =
		[ctx.library newFunctionWithName:clearFlags ? @"clear_fragment" : @"rw_fragment"];
	auto attachment = desc.colorAttachments[0];
	attachment.pixelFormat = ctx.color.pixelFormat;
	attachment.writeMask = clearFlags && !(clearFlags & Camera::CLEARIMAGE) ? MTLColorWriteMaskNone
																			: MTLColorWriteMaskAll;
	attachment.blendingEnabled = alpha;
	attachment.sourceRGBBlendFactor = blend(ctx.states[SRCBLEND]);
	attachment.sourceAlphaBlendFactor = blend(ctx.states[SRCBLEND]);
	attachment.destinationRGBBlendFactor = blend(ctx.states[DESTBLEND]);
	attachment.destinationAlphaBlendFactor = blend(ctx.states[DESTBLEND]);
	if (ctx.depth)
		desc.depthAttachmentPixelFormat = desc.stencilAttachmentPixelFormat = ctx.depth.pixelFormat;
	NSError *error = nil;
	id<MTLRenderPipelineState> state = [ctx.device newRenderPipelineStateWithDescriptor:desc
																				  error:&error];
	if (!state)
		reportError(error.localizedDescription.UTF8String);
	else
		ctx.pipelines[key] = state;
	return state;
}
static id<MTLDepthStencilState> depthState(void)
{
	std::vector<uint32> key;
	key.push_back(ctx.depth != nil);
	key.push_back(ctx.states[ZTESTENABLE]);
	key.push_back(ctx.states[ZWRITEENABLE]);
	for (int i = STENCILENABLE; i <= STENCILFUNCTIONWRITEMASK; i++)
		key.push_back(ctx.states[i]);
	auto it = ctx.depths.find(key);
	if (it != ctx.depths.end())
		return it->second;
	MTLDepthStencilDescriptor *desc = [[MTLDepthStencilDescriptor alloc] init];
	desc.depthCompareFunction = ctx.depth && ctx.states[ZTESTENABLE] ? MTLCompareFunctionLessEqual
																	 : MTLCompareFunctionAlways;
	desc.depthWriteEnabled = ctx.depth && ctx.states[ZWRITEENABLE] != 0;
	if (ctx.depth && ctx.states[STENCILENABLE]) {
		MTLStencilDescriptor *s = [[MTLStencilDescriptor alloc] init];
		s.stencilCompareFunction = compare(ctx.states[STENCILFUNCTION]);
		s.stencilFailureOperation = stencil(ctx.states[STENCILFAIL]);
		s.depthFailureOperation = stencil(ctx.states[STENCILZFAIL]);
		s.depthStencilPassOperation = stencil(ctx.states[STENCILPASS]);
		s.readMask = ctx.states[STENCILFUNCTIONMASK];
		s.writeMask = ctx.states[STENCILFUNCTIONWRITEMASK];
		desc.frontFaceStencil = desc.backFaceStencil = s;
	}
	id<MTLDepthStencilState> state = [ctx.device newDepthStencilStateWithDescriptor:desc];
	ctx.depths[key] = state;
	return state;
}
static id<MTLSamplerState> sampler(int filter, int u, int v)
{
	filter = std::max(1, std::min(filter, 6));
	u = std::max(1, std::min(u, 4));
	v = std::max(1, std::min(v, 4));
	uint32 key = filter | (u << 4) | (v << 8);
	auto it = ctx.samplers.find(key);
	if (it != ctx.samplers.end())
		return it->second;
	MTLSamplerDescriptor *s = [[MTLSamplerDescriptor alloc] init];
	s.minFilter = s.magFilter = filter == Texture::NEAREST || filter == Texture::MIPNEAREST ||
										filter == Texture::LINEARMIPNEAREST
									? MTLSamplerMinMagFilterNearest
									: MTLSamplerMinMagFilterLinear;
	s.mipFilter = filter <= Texture::LINEAR
					  ? MTLSamplerMipFilterNotMipmapped
					  : (filter <= Texture::MIPLINEAR ? MTLSamplerMipFilterNearest
													  : MTLSamplerMipFilterLinear);
	MTLSamplerAddressMode addresses[] = {
		MTLSamplerAddressModeRepeat, MTLSamplerAddressModeRepeat, MTLSamplerAddressModeMirrorRepeat,
		MTLSamplerAddressModeClampToEdge, MTLSamplerAddressModeClampToBorderColor};
	s.sAddressMode = addresses[u];
	s.tAddressMode = addresses[v];
	id<MTLSamplerState> state = [ctx.device newSamplerStateWithDescriptor:s];
	ctx.samplers[key] = state;
	return state;
}
static bool drawSetup(id<MTLTexture> texture, id<MTLTexture> env, Texture *envTexture)
{
	ensurePass(engine->currentCamera);
	if (!ctx.encoder)
		return false;
	Rect r = ctx.viewport;
	[ctx.encoder
		setViewport:(MTLViewport){double(r.x), double(r.y), double(r.w), double(r.h), 0, 1}];
	int x = r.x, y = r.y, w = r.w, h = r.h;
	if (ctx.clipEnabled) {
		float sx = (float)r.w / engine->currentCamera->frameBuffer->width,
			  sy = (float)r.h / engine->currentCamera->frameBuffer->height;
		x = std::max(r.x, r.x + int(ctx.clip[0] * sx));
		y = std::max(r.y, r.y + int(ctx.clip[1] * sy));
		w = std::min(r.x + r.w, r.x + int(std::ceil((ctx.clip[0] + ctx.clip[2]) * sx))) - x;
		h = std::min(r.y + r.h, r.y + int(std::ceil((ctx.clip[1] + ctx.clip[3]) * sy))) - y;
	}
	if (w <= 0 || h <= 0)
		return false;
	[ctx.encoder setScissorRect:(MTLScissorRect){NSUInteger(x), NSUInteger(y), NSUInteger(w),
												 NSUInteger(h)}];
	bool alpha = ctx.states[VERTEXALPHA] != 0;
	Raster *bound = (Raster *)ctx.states[TEXTURERASTER];
	RasterData *raster = rasterData(bound ? bound->parent : nullptr);
	texture = bound && bound->parent->type == Raster::CAMERA ? ctx.backColor
															 : (raster ? raster->texture : texture);
	ctx.uniforms.textureRegion = simd_make_float4(1, 1, 0, 0);
	if (bound && bound != bound->parent) {
		float width = bound->parent->width, height = bound->parent->height;
		ctx.uniforms.textureRegion =
			simd_make_float4(bound->width / width, bound->height / height, bound->offsetX / width,
							 bound->offsetY / height);
	}
	alpha = alpha || (raster && raster->hasAlpha);
	auto p = pipeline(alpha);
	if (!p)
		return false;
	[ctx.encoder setRenderPipelineState:p];
	[ctx.encoder setDepthStencilState:depthState()];
	[ctx.encoder setStencilReferenceValue:ctx.states[STENCILFUNCTIONREF]];
	[ctx.encoder setFrontFacingWinding:MTLWindingCounterClockwise];
	[ctx.encoder
		setCullMode:ctx.states[CULLMODE] == CULLBACK
						? MTLCullModeBack
						: (ctx.states[CULLMODE] == CULLFRONT ? MTLCullModeFront : MTLCullModeNone)];
	ctx.uniforms.alpha = simd_make_float4(alpha ? ctx.states[ALPHATESTFUNC] : ALPHAALWAYS,
										  ctx.states[ALPHATESTREF] / 255.0f, 0, 0);
	uint32 fogColor = ctx.states[FOGCOLOR];
	ctx.uniforms.fogColor = simd_make_float4(fogColor & 255, (fogColor >> 8) & 255,
											 (fogColor >> 16) & 255, (fogColor >> 24) & 255) /
							255.0f;
	ctx.uniforms.fog.z = ctx.states[FOGENABLE];
	[ctx.encoder setVertexBytes:&ctx.uniforms length:sizeof(Uniforms) atIndex:1];
	[ctx.encoder setFragmentBytes:&ctx.uniforms length:sizeof(Uniforms) atIndex:1];
	[ctx.encoder setFragmentTexture:texture ? texture : ctx.white atIndex:0];
	[ctx.encoder setFragmentTexture:env ? env : ctx.white atIndex:1];
	[ctx.encoder
		setFragmentSamplerState:sampler(ctx.states[TEXTUREFILTER], ctx.states[TEXTUREADDRESSU],
										ctx.states[TEXTUREADDRESSV])
						atIndex:0];
	[ctx.encoder
		setFragmentSamplerState:envTexture
									? sampler(envTexture->getFilter(), envTexture->getAddressU(),
											  envTexture->getAddressV())
									: sampler(Texture::LINEAR, Texture::CLAMP, Texture::CLAMP)
						atIndex:1];
	return true;
}
static void convertTexture(Texture *tex)
{
	if (tex && tex->raster && tex->raster->platform != PLATFORM_METAL)
		tex->raster = Raster::convertTexToCurrentPlatform(tex->raster);
}
static void setTexture(Texture *tex)
{
	convertTexture(tex);
	ctx.states[TEXTURERASTER] = (uintptr)(tex ? tex->raster : nullptr);
	if (tex) {
		ctx.states[TEXTUREFILTER] = tex->getFilter();
		ctx.states[TEXTUREADDRESSU] = tex->getAddressU();
		ctx.states[TEXTUREADDRESSV] = tex->getAddressV();
	}
}
static void lights(Atomic *atomic, bool enabled)
{
	ctx.uniforms.flags.x = enabled;
	memset(ctx.uniforms.lightParams, 0, sizeof(ctx.uniforms.lightParams));
	ctx.uniforms.ambient = simd_make_float4(0, 0, 0, 0);
	if (!enabled || !engine->currentWorld)
		return;
	Light *directionals[8], *locals[8];
	WorldLights data = {};
	data.directionals = directionals;
	data.numDirectionals = 8;
	data.locals = locals;
	data.numLocals = 8;
	if (atomic)
		engine->currentWorld->enumerateLights(atomic, &data);
	else
		engine->currentWorld->enumerateLights(&data);
	memcpy(&ctx.uniforms.ambient, &data.ambient, 16);
	int n = 0;
	for (int i = 0; i < data.numDirectionals && n < MaxLights; i++, n++) {
		Light *l = directionals[i];
		V3d d = l->getFrame()->getLTM()->at;
		ctx.uniforms.lightParams[n] = simd_make_float4(1, 0, 0, 0);
		ctx.uniforms.lightDirection[n] = simd_make_float4(d.x, d.y, d.z, 0);
		memcpy(&ctx.uniforms.lightColor[n], &l->color, 16);
	}
	for (int i = 0; i < data.numLocals && n < MaxLights; i++, n++) {
		Light *l = locals[i];
		Matrix *m = l->getFrame()->getLTM();
		ctx.uniforms.lightParams[n] =
			simd_make_float4(l->getType() == Light::POINT ? 2 : 3, l->radius, l->minusCosAngle,
							 l->getType() == Light::SPOT ? 1 : 0);
		ctx.uniforms.lightPosition[n] = simd_make_float4(m->pos.x, m->pos.y, m->pos.z, 0);
		ctx.uniforms.lightDirection[n] = simd_make_float4(m->at.x, m->at.y, m->at.z, 0);
		memcpy(&ctx.uniforms.lightColor[n], &l->color, 16);
	}
}

void *destroyNativeData(void *object, int32, int32)
{
	Geometry *geo = (Geometry *)object;
	if (geo->instData && geo->instData->platform == PLATFORM_METAL) {
		delete (GeometryData *)geo->instData;
		geo->instData = nullptr;
	}
	return object;
}
static bool convertGeometry(Atomic *atomic)
{
	Geometry *geo = atomic->geometry;
	if (!geo->instData)
		return false;
	rw::ObjPipeline *source = nullptr;
	bool skinned = ctx.skinRegistered && Skin::get(geo) != nullptr;
	switch (geo->instData->platform) {
	case PLATFORM_D3D8:
		source = d3d8::makeDefaultPipeline();
		break;
	case PLATFORM_D3D9:
		source = d3d9::makeDefaultPipeline();
		break;
	case PLATFORM_XBOX:
		source = skinned ? xbox::makeSkinPipeline() : xbox::makeDefaultPipeline();
		break;
	case PLATFORM_WDGL:
		source = skinned ? wdgl::makeSkinPipeline() : wdgl::makeDefaultPipeline();
		break;
	case PLATFORM_PS2:
		// PS2 uses registered material/PDS pipelines to unpack native data.
		source = skinned ? skinGlobals.pipelines[PLATFORM_PS2]
						 : engine->driver[PLATFORM_PS2]->defaultPipeline;
		if (source == engine->dummyDefaultPipeline)
			return false;
		source->uninstance(atomic);
		return !(geo->flags & Geometry::NATIVE);
	default:
		return false;
	}
	source->uninstance(atomic);
	source->destroy();
	return !(geo->flags & Geometry::NATIVE);
}
static void instance(rw::ObjPipeline *, Atomic *atomic)
{
	@autoreleasepool {
		Geometry *geo = atomic->geometry;
		if (geo->flags & Geometry::NATIVE &&
			(!geo->instData || geo->instData->platform != PLATFORM_METAL)) {
			if (!convertGeometry(atomic)) {
				reportError("Could not unpack foreign native geometry");
				return;
			}
		}
		if (!geo->meshHeader)
			geo->buildMeshes();
		if (!geo->meshHeader || geo->numVertices <= 0)
			return;
		GeometryData *old = (GeometryData *)geo->instData;
		if (old && old->platform == PLATFORM_METAL && old->serial == geo->meshHeader->serialNum &&
			!geo->lockedSinceInst)
			return;
		destroyNativeData(geo, 0, 0);
		GeometryData *data = new GeometryData;
		data->platform = PLATFORM_METAL;
		data->serial = geo->meshHeader->serialNum;
		data->primitive = geo->meshHeader->flags == MeshHeader::TRISTRIP
							  ? MTLPrimitiveTypeTriangleStrip
							  : MTLPrimitiveTypeTriangle;
		std::vector<Vertex> vertices(geo->numVertices);
		Skin *skin = ctx.skinRegistered ? Skin::get(geo) : nullptr;
		for (int i = 0; i < geo->numVertices; i++) {
			Vertex &v = vertices[i];
			memcpy(v.position, &geo->morphTargets[0].vertices[i], 12);
			if (geo->flags & Geometry::NORMALS)
				memcpy(v.normal, &geo->morphTargets[0].normals[i], 12);
			if (geo->flags & Geometry::PRELIT)
				memcpy(v.color, &geo->colors[i], 4);
			else {
				v.color[0] = v.color[1] = v.color[2] = (geo->flags & Geometry::LIGHT) ? 0 : 255;
				v.color[3] = 255;
			}
			if (geo->numTexCoordSets)
				memcpy(v.uv, &geo->texCoords[0][i], 8);
			if (skin) {
				if (!skin->weights || !skin->indices) {
					delete data;
					reportError("Skin has no vertex weights");
					return;
				}
				memcpy(v.weights, skin->weights + i * 4, 16);
				memcpy(v.bones, skin->indices + i * 4, 4);
				for (int j = 0; j < 4; j++) {
					if (v.weights[j] == 0)
						v.bones[j] = 0;
					else if (v.bones[j] >= skin->numBones) {
						delete data;
						reportError("Skin bone index out of range");
						return;
					}
				}
			}
		}
		std::vector<uint16> indices;
		Mesh *meshes = geo->meshHeader->getMeshes();
		for (uint32 i = 0; i < geo->meshHeader->numMeshes; i++) {
			Mesh &mesh = meshes[i];
			if (!mesh.numIndices)
				continue;
			MeshData m = {uint32(indices.size() * 2), mesh.numIndices, mesh.material, false};
			for (uint32 j = 0; j < mesh.numIndices; j++) {
				if (mesh.indices[j] >= geo->numVertices) {
					delete data;
					reportError("Geometry index out of range");
					return;
				}
				if (vertices[mesh.indices[j]].color[3] != 255)
					m.vertexAlpha = true;
				indices.push_back(mesh.indices[j]);
			}
			data->meshes.push_back(m);
		}
		data->vertices = [ctx.device newBufferWithBytes:vertices.data()
												 length:vertices.size() * sizeof(Vertex)
												options:MTLResourceStorageModeShared];
		if (!indices.empty())
			data->indices = [ctx.device newBufferWithBytes:indices.data()
													length:indices.size() * 2
												   options:MTLResourceStorageModeShared];
		geo->instData = data;
		geo->lockedSinceInst = 0;
	}
}
static void uninstance(rw::ObjPipeline *, Atomic *atomic)
{
	destroyNativeData(atomic->geometry, 0, 0);
	atomic->geometry->flags &= ~Geometry::NATIVE;
}
static BufferSlice bones(Atomic *atomic)
{
	Skin *skin = ctx.skinRegistered ? Skin::get(atomic->geometry) : nullptr;
	ctx.uniforms.flags.z = skin != nullptr;
	if (!skin)
		return {ctx.identityBones, 0};
	int count = skin->numBones;
	if (count <= 0 || count > 256) {
		reportError("Invalid skin bone count");
		ctx.uniforms.flags.z = 0;
		return {ctx.identityBones, 0};
	}
	std::vector<simd_float4x4> matrices(count, matrix_identity_float4x4);
	HAnimHierarchy *hier = Skin::getHierarchy(atomic);
	if (hier && hier->matrices && hier->numNodes == count) {
		Matrix inverseAtomic;
		Matrix::invert(&inverseAtomic, atomic->getFrame()->getLTM());
		for (int i = 0; i < count; i++) {
			Matrix inverseBind, pose, result;
			convMatrix(&inverseBind, (RawMatrix *)(skin->inverseMatrices + i * 16));
			if (hier->flags & HAnimHierarchy::LOCALSPACEMATRICES)
				pose = hier->matrices[i];
			else
				Matrix::mult(&pose, &hier->matrices[i], &inverseAtomic);
			Matrix::mult(&result, &inverseBind, &pose);
			matrices[i] = matrix(&result);
		}
	}
	return upload(matrices.data(), count * sizeof(simd_float4x4));
}
static void environment(Material *material, Texture **texture)
{
	ctx.uniforms.flags.w = 0;
	*texture = nullptr;
	if (!ctx.matfxRegistered)
		return;
	MatFX *fx = MatFX::get(material);
	if (!fx || fx->type != MatFX::ENVMAP || !fx->fx[0].env.tex || fx->fx[0].env.coefficient == 0)
		return;
	MatFX::Env &env = fx->fx[0].env;
	Frame *frame = env.frame ? env.frame : engine->currentCamera->getFrame();
	Matrix inv;
	Matrix::invert(&inv, frame->getLTM());
	inv.pos.set(0, 0, 0);
	simd_float4x4 normal2uv = matrix_identity_float4x4;
	normal2uv.columns[0].x = MatFX::envMapFlipU ? -0.5 : 0.5;
	normal2uv.columns[1].y = -0.5;
	normal2uv.columns[3] = simd_make_float4(0.5, 0.5, 0, 1);
	ctx.uniforms.envMatrix = simd_mul(normal2uv, matrix(&inv));
	ctx.uniforms.envParams =
		simd_make_float4(env.coefficient, env.fbAlpha ? 0 : 1, MatFX::envMapApplyLight ? 0 : 1, 0);
	ctx.uniforms.envColor = color(MatFX::envMapUseMatColor ? material->color : MatFX::envMapColor);
	ctx.uniforms.flags.w = 1;
	*texture = env.tex;
	convertTexture(env.tex);
}
static void render(rw::ObjPipeline *pipe, Atomic *atomic)
{
	@autoreleasepool {
		instance(pipe, atomic);
		GeometryData *data = (GeometryData *)atomic->geometry->instData;
		if (!data || data->platform != PLATFORM_METAL)
			return;
		ensurePass(engine->currentCamera);
		ctx.uniforms.flags.y = 0;
		ctx.uniforms.world = matrix(atomic->getFrame()->getLTM());
		lights(atomic, (atomic->geometry->flags & Geometry::LIGHT) != 0);
		BufferSlice boneBuffer = bones(atomic);
		if (!boneBuffer.buffer)
			return;
		for (auto &m : data->meshes) {
			Material *material = m.material;
			ctx.uniforms.material = atomic->geometry->flags & Geometry::MODULATE
										? color(material->color)
										: simd_make_float4(1, 1, 1, 1);
			ctx.uniforms.surface =
				simd_make_float4(material->surfaceProps.ambient, material->surfaceProps.specular,
								 material->surfaceProps.diffuse, 0);
			setTexture(material->texture);
			ctx.states[VERTEXALPHA] = m.vertexAlpha || material->color.alpha != 255;
			Texture *envTexture;
			environment(material, &envTexture);
			uintptr oldSource = ctx.states[SRCBLEND];
			if (envTexture) {
				ctx.states[VERTEXALPHA] = 1;
				ctx.states[SRCBLEND] = BLENDONE;
			}
			auto draw = [&]() {
				RasterData *texture =
					rasterData(material->texture ? material->texture->raster : nullptr);
				RasterData *env = rasterData(envTexture ? envTexture->raster : nullptr);
				if (!drawSetup(texture ? texture->texture : nil, env ? env->texture : nil,
							   envTexture))
					return;
				[ctx.encoder setVertexBuffer:data->vertices offset:0 atIndex:0];
				[ctx.encoder setVertexBuffer:boneBuffer.buffer offset:boneBuffer.offset atIndex:2];
				[ctx.encoder drawIndexedPrimitives:data->primitive
										indexCount:m.count
										 indexType:MTLIndexTypeUInt16
									   indexBuffer:data->indices
								 indexBufferOffset:m.offset];
			};
			RasterData *texture =
				rasterData(material->texture ? material->texture->raster : nullptr);
			bool alpha = ctx.states[VERTEXALPHA] || (texture && texture->hasAlpha);
			if (ctx.states[GSALPHATEST] && alpha) {
				uintptr func = ctx.states[ALPHATESTFUNC], ref = ctx.states[ALPHATESTREF],
						z = ctx.states[ZWRITEENABLE];
				if (z) {
					ctx.states[ALPHATESTFUNC] = ALPHAGREATEREQUAL;
					ctx.states[ALPHATESTREF] = ctx.states[GSALPHATESTREF];
					draw();
					ctx.states[ALPHATESTFUNC] = ALPHALESS;
					ctx.states[ZWRITEENABLE] = 0;
					draw();
				} else {
					ctx.states[ALPHATESTFUNC] = ALPHAALWAYS;
					draw();
				}
				ctx.states[ALPHATESTFUNC] = func;
				ctx.states[ALPHATESTREF] = ref;
				ctx.states[ZWRITEENABLE] = z;
			} else
				draw();
			ctx.states[SRCBLEND] = oldSource;
		}
	}
}
static rw::ObjPipeline *makePipeline(uint32 plugin)
{
	rw::ObjPipeline *p = rw::ObjPipeline::create();
	p->init(PLATFORM_METAL);
	p->pluginID = plugin;
	p->impl.instance = instance;
	p->impl.uninstance = uninstance;
	p->impl.render = render;
	return p;
}

static void immediate(PrimitiveType primitive, const std::vector<Vertex> &vertices, void *indices,
					  int count)
{
	@autoreleasepool {
		if (vertices.empty() || count <= 0)
			return;
		RasterData *texture = rasterData((Raster *)ctx.states[TEXTURERASTER]);
		if (!drawSetup(texture ? texture->texture : nil, nil, nullptr))
			return;
		BufferSlice vertexBuffer = upload(vertices.data(), vertices.size() * sizeof(Vertex));
		if (!vertexBuffer.buffer)
			return;
		[ctx.encoder setVertexBuffer:vertexBuffer.buffer offset:vertexBuffer.offset atIndex:0];
		[ctx.encoder setVertexBuffer:ctx.identityBones offset:0 atIndex:2];
		static MTLPrimitiveType types[] = {MTLPrimitiveTypePoint,		  MTLPrimitiveTypeLine,
										   MTLPrimitiveTypeLineStrip,	  MTLPrimitiveTypeTriangle,
										   MTLPrimitiveTypeTriangleStrip, MTLPrimitiveTypeTriangle,
										   MTLPrimitiveTypePoint};
		if (primitive < PRIMTYPELINELIST || primitive > PRIMTYPEPOINTLIST)
			return;
		std::vector<uint16> fan;
		if (primitive == PRIMTYPETRIFAN) {
			uint16 *src = (uint16 *)indices;
			for (int i = 1; i < count - 1; i++) {
				fan.push_back(src ? src[0] : 0);
				fan.push_back(src ? src[i] : i);
				fan.push_back(src ? src[i + 1] : i + 1);
			}
			indices = fan.data();
			count = fan.size();
		}
		if (indices && count) {
			for (int i = 0; i < count; i++)
				if (((uint16 *)indices)[i] >= vertices.size()) {
					reportError("Immediate index out of range");
					return;
				}
			BufferSlice buffer = upload(indices, count * sizeof(uint16));
			if (!buffer.buffer)
				return;
			[ctx.encoder drawIndexedPrimitives:types[primitive]
									indexCount:count
									 indexType:MTLIndexTypeUInt16
								   indexBuffer:buffer.buffer
							 indexBufferOffset:buffer.offset];
		} else
			[ctx.encoder drawPrimitives:types[primitive] vertexStart:0 vertexCount:count];
	}
}
static std::vector<Vertex> vertices2D(void *input, int count)
{
	std::vector<Vertex> out(std::max(count, 0));
	Im2DVertex *src = (Im2DVertex *)input;
	for (int i = 0; i < count; i++) {
		out[i].position[0] = src[i].x;
		out[i].position[1] = src[i].y;
		out[i].position[2] = src[i].z;
		out[i].normal[0] = src[i].w;
		memcpy(out[i].color, &src[i].r, 4);
		out[i].uv[0] = src[i].u;
		out[i].uv[1] = src[i].v;
	}
	ctx.uniforms.flags = simd_make_uint4(0, 1, 0, 0);
	ctx.uniforms.material = simd_make_float4(1, 1, 1, 1);
	return out;
}
static void im2DRenderPrimitive(PrimitiveType p, void *v, int32 n)
{
	auto out = vertices2D(v, n);
	immediate(p, out, nullptr, n);
}
static void im2DRenderIndexedPrimitive(PrimitiveType p, void *v, int32 n, void *indices,
									   int32 count)
{
	auto out = vertices2D(v, n);
	immediate(p, out, indices, count);
}
static void im2DRenderLine(void *v, int32 n, int32 a, int32 b)
{
	uint16 indices[] = {uint16(a), uint16(b)};
	im2DRenderIndexedPrimitive(PRIMTYPELINELIST, v, n, indices, 2);
}
static void im2DRenderTriangle(void *v, int32 n, int32 a, int32 b, int32 c)
{
	uint16 indices[] = {uint16(a), uint16(b), uint16(c)};
	im2DRenderIndexedPrimitive(PRIMTYPETRILIST, v, n, indices, 3);
}
static void im3DTransform(void *v, int32 count, Matrix *world, uint32 flags)
{
	ctx.immediate.resize(std::max(count, 0));
	ctx.immediateFlags = flags;
	if (world)
		ctx.immediateWorld = *world;
	else
		ctx.immediateWorld.setIdentity();
	Im3DVertex *src = (Im3DVertex *)v;
	for (int i = 0; i < count; i++) {
		Vertex &dst = ctx.immediate[i];
		memset(&dst, 0, sizeof(dst));
		memcpy(dst.position, &src[i].position, 12);
		if (flags & im3d::LIGHTING)
			memcpy(dst.normal, &src[i].normal, 12);
		memcpy(dst.color, &src[i].r, 4);
		dst.uv[0] = src[i].u;
		dst.uv[1] = src[i].v;
	}
	if (!(flags & im3d::VERTEXUV))
		ctx.states[TEXTURERASTER] = 0;
}
static void prepare3D(void)
{
	ctx.uniforms.flags = simd_make_uint4(0, 0, 0, 0);
	ctx.uniforms.world = matrix(&ctx.immediateWorld);
	ctx.uniforms.material = ctx.immediateFlags & im3d::LIGHTING ? color(im3dMaterialColor)
																: simd_make_float4(1, 1, 1, 1);
	ctx.uniforms.surface = simd_make_float4(im3dSurfaceProps.ambient, im3dSurfaceProps.specular,
											im3dSurfaceProps.diffuse, 0);
	lights(nullptr, (ctx.immediateFlags & im3d::LIGHTING) != 0);
}
static void im3DRenderPrimitive(PrimitiveType p)
{
	prepare3D();
	immediate(p, ctx.immediate, nullptr, ctx.immediate.size());
}
static void im3DRenderIndexedPrimitive(PrimitiveType p, void *i, int32 n)
{
	prepare3D();
	immediate(p, ctx.immediate, i, n);
}
static void im3DEnd(void)
{
	ctx.immediate.clear();
}
static bool32 rasterRenderFast(Raster *raster, int32 x, int32 y)
{
	@autoreleasepool {
		Raster *target = Raster::getCurrentContext();
		if (!target || target->type == Raster::ZBUFFER || !raster ||
			raster->platform != PLATFORM_METAL)
			return false;
		// Render a textured copy so BGRA camera targets and RGBA textures convert correctly.
		endPass();
		Camera *oldCamera = engine->currentCamera;
		Camera copyCamera = {};
		copyCamera.frameBuffer = target;
		Uniforms savedUniforms = ctx.uniforms;
		uintptr savedStates[GSALPHATESTREF + 1];
		memcpy(savedStates, ctx.states, sizeof(savedStates));
		engine->currentCamera = &copyCamera;
		ctx.uniforms.window = simd_make_float4(target->width, target->height, 0, 0);
		ctx.states[TEXTURERASTER] = (uintptr)raster;
		ctx.states[TEXTUREFILTER] = Texture::NEAREST;
		ctx.states[TEXTUREADDRESSU] = ctx.states[TEXTUREADDRESSV] = Texture::CLAMP;
		ctx.states[ZTESTENABLE] = ctx.states[ZWRITEENABLE] = ctx.states[STENCILENABLE] =
			ctx.states[FOGENABLE] = ctx.states[VERTEXALPHA] = 0;
		ctx.states[CULLMODE] = CULLNONE;
		ctx.states[SRCBLEND] = BLENDONE;
		ctx.states[DESTBLEND] = BLENDZERO;
		ctx.states[ALPHATESTFUNC] = ALPHAALWAYS;
		Im2DVertex v[4] = {};
		float xs[] = {float(x), float(x + raster->width), float(x + raster->width), float(x)};
		float ys[] = {float(y), float(y), float(y + raster->height), float(y + raster->height)};
		for (int i = 0; i < 4; i++) {
			v[i].x = xs[i];
			v[i].y = ys[i];
			v[i].w = 1;
			v[i].r = v[i].g = v[i].b = v[i].a = 255;
			v[i].u = i == 1 || i == 2;
			v[i].v = i >= 2;
		}
		bool savedClip = ctx.clipEnabled;
		ctx.clipEnabled = false;
		im2DRenderPrimitive(PRIMTYPETRIFAN, v, 4);
		endPass();
		ctx.camera = nullptr;
		ctx.uniforms = savedUniforms;
		memcpy(ctx.states, savedStates, sizeof(savedStates));
		ctx.clipEnabled = savedClip;
		engine->currentCamera = oldCamera;
		return !ctx.failed;
	}
}

static bool makeVideoModeList(void)
{
	ctx.monitor = glfwGetPrimaryMonitor();
	if (!ctx.monitor)
		return false;
	const GLFWvidmode *desktop = glfwGetVideoMode(ctx.monitor);
	if (!desktop)
		return false;
	ctx.modes.clear();
	ctx.currentMode = 0;
	DisplayMode windowed = {*desktop, 0};
	windowed.mode.width = ctx.params.width;
	windowed.mode.height = ctx.params.height;
	ctx.modes.push_back(windowed);
	// On macOS, the current scaled desktop mode may be absent from GLFW's
	// fullscreen list. reVC uses its dimensions as the initial mode preference.
	ctx.modes.push_back({*desktop, VIDEOMODEEXCLUSIVE});
	int count = 0;
	const GLFWvidmode *modes = glfwGetVideoModes(ctx.monitor, &count);
	for (int i = 0; i < count; i++) {
		bool found = false;
		for (size_t j = 1; j < ctx.modes.size(); j++) {
			GLFWvidmode &mode = ctx.modes[j].mode;
			if (mode.width == modes[i].width && mode.height == modes[i].height) {
				if (mode.refreshRate < modes[i].refreshRate)
					mode = modes[i];
				found = true;
				break;
			}
		}
		if (!found)
			ctx.modes.push_back({modes[i], VIDEOMODEEXCLUSIVE});
	}
	return true;
}

static int deviceSystem(DeviceReq request, void *arg, int32 n)
{
	@autoreleasepool {
		switch (request) {
		case DEVICEOPEN:
			ctx.params = *(EngineOpenParams *)arg;
			ctx.windowOut = ctx.params.window;
			if (!glfwInit())
				return 0;
			ctx.device = MTLCreateSystemDefaultDevice();
			if (!ctx.device) {
				reportError("No Metal device available");
				glfwTerminate();
				return 0;
			}
			if (!makeVideoModeList()) {
				reportError("Could not enumerate display modes");
				ctx.device = nil;
				glfwTerminate();
				return 0;
			}
			ctx.name = ctx.device.name.UTF8String;
			return 1;
		case DEVICEINIT: {
			ctx.failed = false;
			glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
			const DisplayMode &mode = ctx.modes[ctx.currentMode];
			glfwWindowHint(GLFW_RED_BITS, mode.mode.redBits);
			glfwWindowHint(GLFW_GREEN_BITS, mode.mode.greenBits);
			glfwWindowHint(GLFW_BLUE_BITS, mode.mode.blueBits);
			glfwWindowHint(GLFW_REFRESH_RATE, mode.mode.refreshRate);
			ctx.window = glfwCreateWindow(mode.mode.width, mode.mode.height,
											  ctx.params.windowtitle,
											  mode.flags & VIDEOMODEEXCLUSIVE ? ctx.monitor : nullptr,
											  nullptr);
			if (!ctx.window) {
				reportError("Could not create window");
				return 0;
			}
			*ctx.windowOut = ctx.window;
			NSWindow *window = glfwGetCocoaWindow(ctx.window);
			ctx.layer = [CAMetalLayer layer];
			ctx.layer.device = ctx.device;
			ctx.layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
			ctx.layer.framebufferOnly = NO;
			window.contentView.wantsLayer = YES;
			window.contentView.layer = ctx.layer;
			ctx.layer.contentsScale = window.backingScaleFactor;
			ctx.queue = [ctx.device newCommandQueue];
			ctx.frameSlots = dispatch_semaphore_create(3);
			NSError *error = nil;
			ctx.library =
				[ctx.device newLibraryWithSource:[NSString stringWithUTF8String:metalShaderSource]
										 options:nil
										   error:&error];
			if (!ctx.library) {
				reportError(error.localizedDescription.UTF8String);
				ctx.queue = nil;
				ctx.layer = nil;
				glfwDestroyWindow(ctx.window);
				ctx.window = nullptr;
				*ctx.windowOut = nullptr;
				return 0;
			}
			ctx.white = makeTexture(1, 1, MTLPixelFormatRGBA8Unorm, false, false);
			uint32 white = 0xFFFFFFFF;
			[ctx.white replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
						 mipmapLevel:0
						   withBytes:&white
						 bytesPerRow:4];
			simd_float4x4 ident = matrix_identity_float4x4;
			ctx.identityBones = [ctx.device newBufferWithBytes:&ident
														length:64
													   options:MTLResourceStorageModeShared];
			memset(ctx.states, 0, sizeof(ctx.states));
			ctx.states[SRCBLEND] = BLENDSRCALPHA;
			ctx.states[DESTBLEND] = BLENDINVSRCALPHA;
			ctx.states[ZTESTENABLE] = ctx.states[ZWRITEENABLE] = 1;
			ctx.states[CULLMODE] = CULLNONE;
			ctx.states[TEXTUREFILTER] = Texture::LINEAR;
			ctx.states[TEXTUREADDRESSU] = ctx.states[TEXTUREADDRESSV] = Texture::WRAP;
			ctx.states[ALPHATESTFUNC] = ALPHAGREATEREQUAL;
			ctx.states[ALPHATESTREF] = 10;
			ctx.states[GSALPHATESTREF] = 128;
			ctx.states[STENCILFUNCTION] = STENCILALWAYS;
			ctx.states[STENCILFAIL] = ctx.states[STENCILZFAIL] = ctx.states[STENCILPASS] =
				STENCILKEEP;
			ctx.states[STENCILFUNCTIONMASK] = ctx.states[STENCILFUNCTIONWRITEMASK] = 0xFFFFFFFF;
			ctx.uniforms.world = ctx.uniforms.envMatrix = ident;
			return 1;
		}
		case DEVICEFINALIZE:
			return 1;
		case DEVICETERM:
			waitIdle();
			ctx.pipelines.clear();
			ctx.depths.clear();
			ctx.samplers.clear();
			ctx.library = nil;
			ctx.white = nil;
			ctx.identityBones = nil;
			ctx.backColor = nil;
			ctx.backDepth = nil;
			ctx.backMultisample = nil;
			ctx.color = nil;
			ctx.depth = nil;
			ctx.renderColor = nil;
			ctx.camera = nullptr;
			ctx.lastCommand = nil;
			ctx.queue = nil;
			ctx.layer = nil;
			glfwDestroyWindow(ctx.window);
			ctx.window = nullptr;
			*ctx.windowOut = nullptr;
			return 1;
		case DEVICECLOSE:
			ctx.device = nil;
			ctx.modes.clear();
			ctx.monitor = nullptr;
			glfwTerminate();
			return 1;
		case DEVICEGETNUMSUBSYSTEMS:
			return 1;
		case DEVICEGETCURRENTSUBSYSTEM:
			return 0;
		case DEVICESETSUBSYSTEM:
			return n == 0;
		case DEVICEGETSUBSSYSTEMINFO:
			snprintf(((SubSystemInfo *)arg)->name, sizeof(((SubSystemInfo *)arg)->name), "%s",
					 ctx.name.c_str());
			return 1;
		case DEVICEGETNUMVIDEOMODES:
			return ctx.modes.size();
		case DEVICEGETCURRENTVIDEOMODE:
			return ctx.currentMode;
		case DEVICESETVIDEOMODE:
			if (Engine::state != Engine::Opened || n < 0 || size_t(n) >= ctx.modes.size())
				return 0;
			ctx.currentMode = n;
			return 1;
		case DEVICEGETVIDEOMODEINFO:
			if (n < 0 || size_t(n) >= ctx.modes.size())
				return 0;
			*(VideoMode *)arg = {ctx.modes[n].mode.width, ctx.modes[n].mode.height, 32,
								ctx.modes[n].flags};
			return 1;
		case DEVICEGETMAXMULTISAMPLINGLEVELS:
			for (int sample = 8; sample >= 1; sample /= 2)
				if ([ctx.device supportsTextureSampleCount:sample])
					return sample;
			return 1;
		case DEVICEGETMULTISAMPLINGLEVELS:
			return ctx.samples;
		case DEVICESETMULTISAMPLINGLEVELS:
			if (Engine::state != Engine::Opened || n < 1 ||
				![ctx.device supportsTextureSampleCount:n])
				return 0;
			ctx.samples = n;
			return 1;
		}
		return 0;
	}
}
Device renderdevice = {0,
					   1,
					   beginUpdate,
					   endUpdate,
					   clearCamera,
					   showRaster,
					   rasterRenderFast,
					   setRenderState,
					   getRenderState,
					   im2DRenderLine,
					   im2DRenderTriangle,
					   im2DRenderPrimitive,
					   im2DRenderIndexedPrimitive,
					   im3DTransform,
					   im3DRenderPrimitive,
					   im3DRenderIndexedPrimitive,
					   im3DEnd,
					   deviceSystem};

static void *driverOpen(void *o, int32, int32)
{
	Driver *d = engine->driver[PLATFORM_METAL];
	defaultPipeline = makePipeline(0);
	d->defaultPipeline = defaultPipeline;
	d->rasterNativeOffset = nativeRasterOffset;
	d->rasterCreate = rasterCreate;
	d->rasterLock = rasterLock;
	d->rasterUnlock = rasterUnlock;
	d->rasterNumLevels = rasterNumLevels;
	d->imageFindRasterFormat = imageFindRasterFormat;
	d->rasterFromImage = rasterFromImage;
	d->rasterToImage = rasterToImage;
	return o;
}
static void *driverClose(void *o, int32, int32)
{
	defaultPipeline->destroy();
	defaultPipeline = nullptr;
	return o;
}
void registerPlatformPlugins(void)
{
	ctx.skinRegistered = ctx.matfxRegistered = false;
	ctx.samples = 1;
	Driver::registerPlugin(PLATFORM_METAL, 0, PLATFORM_METAL, driverOpen, driverClose);
	registerRaster();
}
static void *skinOpen(void *o, int32, int32)
{
	skinPipeline = makePipeline(ID_SKIN);
	skinGlobals.pipelines[PLATFORM_METAL] = skinPipeline;
	return o;
}
static void *skinClose(void *o, int32, int32)
{
	skinPipeline->destroy();
	skinGlobals.pipelines[PLATFORM_METAL] = nullptr;
	return o;
}
static void *matfxOpen(void *o, int32, int32)
{
	matfxPipeline = makePipeline(ID_MATFX);
	matFXGlobals.pipelines[PLATFORM_METAL] = matfxPipeline;
	return o;
}
static void *matfxClose(void *o, int32, int32)
{
	matfxPipeline->destroy();
	matFXGlobals.pipelines[PLATFORM_METAL] = nullptr;
	return o;
}
void initSkin(void)
{
	ctx.skinRegistered = true;
	Driver::registerPlugin(PLATFORM_METAL, 0, ID_SKIN, skinOpen, skinClose);
}
void initMatFX(void)
{
	ctx.matfxRegistered = true;
	Driver::registerPlugin(PLATFORM_METAL, 0, ID_MATFX, matfxOpen, matfxClose);
}
} // namespace metal
} // namespace rw
