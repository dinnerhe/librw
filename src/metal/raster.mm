#include "../../rw.h"
#include "metalimpl.h"
#include <algorithm>
#include <cstring>

namespace rw
{
namespace metal
{
// RenderWare locks retain their CPU pixel layout while textures use RGBA8.
static uint16 pack(uint8 *p, int f)
{
	if (f == Raster::C565)
		return ((p[0] >> 3) << 11) | ((p[1] >> 2) << 5) | (p[2] >> 3);
	if (f == Raster::C4444)
		return ((p[3] >> 4) << 12) | ((p[0] >> 4) << 8) | ((p[1] >> 4) << 4) | (p[2] >> 4);
	return (p[3] >= 128 ? 0x8000 : 0) | ((p[0] >> 3) << 10) | ((p[1] >> 3) << 5) | (p[2] >> 3);
}
static void unpack(uint8 *out, uint8 *p, int f)
{
	uint16 value;
	memcpy(&value, p, 2);
	if (f == Raster::C565) {
		out[0] = ((value >> 11) & 31) * 255 / 31;
		out[1] = ((value >> 5) & 63) * 255 / 63;
		out[2] = (value & 31) * 255 / 31;
		out[3] = 255;
	} else if (f == Raster::C4444) {
		out[0] = ((value >> 8) & 15) * 17;
		out[1] = ((value >> 4) & 15) * 17;
		out[2] = (value & 15) * 17;
		out[3] = ((value >> 12) & 15) * 17;
	} else {
		out[0] = ((value >> 10) & 31) * 255 / 31;
		out[1] = ((value >> 5) & 31) * 255 / 31;
		out[2] = (value & 31) * 255 / 31;
		out[3] = f == Raster::C555 || (value & 0x8000) ? 255 : 0;
	}
}
static void packPixel(uint8 *out, uint8 *p, int f)
{
	uint16 v = pack(p, f);
	memcpy(out, &v, 2);
}
int32 nativeRasterOffset;
RasterData *rasterData(Raster *raster)
{
	if (!raster || raster->platform != PLATFORM_METAL)
		return nullptr;
	return *PLUGINOFFSET(RasterData *, raster, nativeRasterOffset);
}

id<MTLTexture> makeTexture(int width, int height, MTLPixelFormat format, bool mipmaps,
						   bool renderTarget)
{
	if (width <= 0 || height <= 0 || !ctx.device)
		return nil;
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
																				 width:width
																				height:height
																			 mipmapped:mipmaps];
	d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
	d.storageMode =
		renderTarget ? MTLStorageModePrivate
					 : (ctx.device.hasUnifiedMemory ? MTLStorageModeShared : MTLStorageModeManaged);
	return [ctx.device newTextureWithDescriptor:d];
}

id<MTLTexture> makeMultisampleTexture(int width, int height, MTLPixelFormat format)
{
	if (ctx.samples == 1)
		return makeTexture(width, height, format, false, true);
	MTLTextureDescriptor *d = [[MTLTextureDescriptor alloc] init];
	d.textureType = MTLTextureType2DMultisample;
	d.pixelFormat = format;
	d.width = width;
	d.height = height;
	d.sampleCount = ctx.samples;
	d.storageMode = MTLStorageModePrivate;
	d.usage = MTLTextureUsageRenderTarget;
	return [ctx.device newTextureWithDescriptor:d];
}

static void *constructRaster(void *o, int32 offset, int32)
{
	*PLUGINOFFSET(RasterData *, o, offset) = new RasterData;
	return o;
}
static void *destructRaster(void *o, int32 offset, int32)
{
	if (ctx.states[TEXTURERASTER] == (uintptr)o)
		ctx.states[TEXTURERASTER] = 0;
	delete *PLUGINOFFSET(RasterData *, o, offset);
	return o;
}
static void *copyRaster(void *dst, void *src, int32 offset, int32)
{
	RasterData *a = *PLUGINOFFSET(RasterData *, dst, offset);
	RasterData *b = *PLUGINOFFSET(RasterData *, src, offset);
	a->texture = b->texture;
	a->multisample = b->multisample;
	a->hasAlpha = b->hasAlpha;
	return dst;
}
void registerRaster(void)
{
	nativeRasterOffset =
		Raster::registerPlugin(sizeof(RasterData *), MAKEPLUGINID(VEND_RASTER, PLATFORM_METAL),
							   constructRaster, destructRaster, copyRaster);
}

Raster *rasterCreate(Raster *raster)
{
	@autoreleasepool {
		RasterData *data = rasterData(raster);
		if (raster->format & (Raster::PAL4 | Raster::PAL8)) {
			reportError("Palettized GPU rasters must be converted through Image");
			raster->destroy();
			return nullptr;
		}
		if (!(raster->format & 0xF00))
			raster->format |= raster->type == Raster::ZBUFFER ? Raster::D32 : Raster::C8888;
		// CPU locks expose the requested RenderWare format; GPU storage is RGBA8.
		int f = raster->format & 0xF00;
		raster->depth =
			f == Raster::C888
				? 24
				: (f == Raster::C8888 || f == Raster::D32 ? 32 : (f == Raster::LUM8 ? 8 : 16));
		raster->stride = raster->width * (raster->depth / 8);
		raster->originalWidth = raster->width;
		raster->originalHeight = raster->height;
		raster->originalStride = raster->stride;
		data->hasAlpha = Raster::formatHasAlpha(raster->format);
		if (raster->width <= 0 || raster->height <= 0)
			raster->flags |= Raster::DONTALLOCATE;
		if (raster->flags & Raster::DONTALLOCATE || raster->type == Raster::CAMERA)
			return raster;
		bool depth = raster->type == Raster::ZBUFFER;
		data->texture = depth ? makeMultisampleTexture(raster->width, raster->height,
													   MTLPixelFormatDepth32Float_Stencil8)
							  : makeTexture(raster->width, raster->height, MTLPixelFormatRGBA8Unorm,
											(raster->format & Raster::MIPMAP) != 0,
											raster->type == Raster::CAMERATEXTURE);
		if (!depth && raster->type == Raster::CAMERATEXTURE && ctx.samples > 1)
			data->multisample =
				makeMultisampleTexture(raster->width, raster->height, MTLPixelFormatRGBA8Unorm);
		if (!data->texture) {
			reportError("Could not allocate raster texture");
			raster->destroy();
			return nullptr;
		}
		return raster;
	}
}

int32 rasterNumLevels(Raster *raster)
{
	RasterData *data = rasterData(raster);
	return data && data->texture ? (int32)data->texture.mipmapLevelCount : 1;
}

static std::vector<uint8> readTexture(id<MTLTexture> texture, int level, int x, int y, int width,
									  int height)
{
	if (!texture || width <= 0 || height <= 0 || x < 0 || y < 0 ||
		x + width > (int)std::max(NSUInteger(1), texture.width >> level) ||
		y + height > (int)std::max(NSUInteger(1), texture.height >> level))
		return {};
	std::vector<uint8> pixels(width * height * 4);
	endPass();
	ensureCommand();
	size_t stride = (width * 4 + 255) & ~255;
	id<MTLBuffer> buffer = [ctx.device newBufferWithLength:stride * height
												   options:MTLResourceStorageModeShared];
	id<MTLBlitCommandEncoder> encoder = [ctx.command blitCommandEncoder];
	[encoder copyFromTexture:texture
					 sourceSlice:0
					 sourceLevel:level
					sourceOrigin:MTLOriginMake(x, y, 0)
					  sourceSize:MTLSizeMake(width, height, 1)
						toBuffer:buffer
			   destinationOffset:0
		  destinationBytesPerRow:stride
		destinationBytesPerImage:stride * height];
	[encoder endEncoding];
	if (!submit(true))
		return {};
	const uint8 *src = (const uint8 *)buffer.contents;
	bool bgra = texture.pixelFormat == MTLPixelFormatBGRA8Unorm;
	for (int row = 0; row < height; row++) {
		memcpy(pixels.data() + row * width * 4, src + row * stride, width * 4);
		if (bgra)
			for (int col = 0; col < width; col++)
				std::swap(pixels[(row * width + col) * 4], pixels[(row * width + col) * 4 + 2]);
	}
	return pixels;
}

uint8 *rasterLock(Raster *raster, int32 level, int32 mode)
{
	@autoreleasepool {
		RasterData *data = rasterData(raster);
		if (!data || data->level >= 0 || level < 0 || level >= rasterNumLevels(raster) ||
			raster->type == Raster::ZBUFFER)
			return nullptr;
		int width = std::max(
			1, (raster == raster->parent ? raster->originalWidth : raster->width) >> level);
		int height = std::max(
			1, (raster == raster->parent ? raster->originalHeight : raster->height) >> level);
		id<MTLTexture> texture = rasterData(raster->parent)->texture;
		if (raster->type == Raster::CAMERA) {
			texture = ctx.backColor;
			if (!texture)
				return nullptr;
			width = raster == raster->parent ? (int)texture.width : raster->width;
			height = raster == raster->parent ? (int)texture.height : raster->height;
			raster->depth = 32;
		}
		if (mode & Raster::LOCKREAD && !texture)
			return nullptr;
		int bpp = raster->depth / 8;
		data->locked.resize(width * height * bpp);
		if (!(mode & Raster::LOCKNOFETCH)) {
			auto pixels =
				readTexture(texture, level, raster->offsetX, raster->offsetY, width, height);
			if (pixels.empty())
				return nullptr;
			for (int i = 0; i < width * height; i++) {
				uint8 *p = pixels.data() + i * 4;
				uint8 *out = data->locked.data() + i * bpp;
				switch (raster->format & 0xF00) {
				case Raster::C888:
					memcpy(out, p, 3);
					break;
				case Raster::C1555:
				case Raster::C555:
					packPixel(out, p, raster->format & 0xF00);
					break;
				case Raster::C565:
					packPixel(out, p, Raster::C565);
					break;
				case Raster::C4444:
					packPixel(out, p, Raster::C4444);
					break;
				case Raster::LUM8:
					*out = p[0];
					break;
				default:
					memcpy(out, p, 4);
					break;
				}
			}
		}
		raster->originalWidth = raster->width;
		raster->originalHeight = raster->height;
		raster->originalStride = raster->stride;
		data->level = level;
		data->mode = mode;
		raster->width = width;
		raster->height = height;
		raster->stride = width * bpp;
		raster->pixels = data->locked.data();
		raster->privateFlags = (mode & Raster::LOCKWRITE ? Raster::PRIVATELOCK_WRITE : 0) |
							   (mode & Raster::LOCKREAD ? Raster::PRIVATELOCK_READ : 0);
		return raster->pixels;
	}
}

void rasterUnlock(Raster *raster, int32 level)
{
	@autoreleasepool {
		RasterData *data = rasterData(raster);
		if (!data || data->level != level)
			return;
		if (data->mode & Raster::LOCKWRITE) {
			int width = raster->width, height = raster->height, bpp = raster->depth / 8;
			std::vector<uint8> rgba(width * height * 4);
			for (int i = 0; i < width * height; i++) {
				uint8 *out = rgba.data() + i * 4;
				uint8 *p = data->locked.data() + i * bpp;
				switch (raster->format & 0xF00) {
				case Raster::C888:
					conv_RGBA8888_from_RGB888(out, p);
					break;
				case Raster::C1555:
				case Raster::C555:
					unpack(out, p, raster->format & 0xF00);
					break;
				case Raster::C565:
					unpack(out, p, Raster::C565);
					break;
				case Raster::C4444:
					unpack(out, p, Raster::C4444);
					break;
				case Raster::LUM8:
					out[0] = out[1] = out[2] = p[0];
					out[3] = 255;
					break;
				default:
					memcpy(out, p, 4);
					break;
				}
				if (out[3] != 255)
					data->hasAlpha = true;
			}
			// Queue the upload after earlier draws, including draws in this command.
			// This preserves texture-write ordering without stalling the CPU for
			// every texture or mip level streamed by the game.
			endPass();
			ensureCommand();
			id<MTLTexture> texture = rasterData(raster->parent)->texture;
			{
				size_t stride = (width * 4 + 255) & ~255;
				BufferSlice staging = allocateUpload(stride * height);
				if (!staging.buffer)
					return;
				for (int row = 0; row < height; row++)
					memcpy((uint8 *)staging.buffer.contents + staging.offset + row * stride,
						   rgba.data() + row * width * 4,
						   width * 4);
				id<MTLBlitCommandEncoder> enc = [ctx.command blitCommandEncoder];
				[enc copyFromBuffer:staging.buffer
						   sourceOffset:staging.offset
					  sourceBytesPerRow:stride
					sourceBytesPerImage:stride * height
							 sourceSize:MTLSizeMake(width, height, 1)
							  toTexture:texture
					   destinationSlice:0
					   destinationLevel:level
					  destinationOrigin:MTLOriginMake(raster->offsetX, raster->offsetY, 0)];
				[enc endEncoding];
			}
			if (level == 0 && (raster->format & Raster::AUTOMIPMAP) &&
				texture.mipmapLevelCount > 1) {
				ensureCommand();
				id<MTLBlitCommandEncoder> enc = [ctx.command blitCommandEncoder];
				[enc generateMipmapsForTexture:texture];
				[enc endEncoding];
			}
		}
		data->level = -1;
		data->locked.clear();
		raster->pixels = nullptr;
		raster->privateFlags = 0;
		raster->width = raster->originalWidth;
		raster->height = raster->originalHeight;
		raster->stride = raster->originalStride;
	}
}

bool32 imageFindRasterFormat(Image *image, int32 type, int32 *width, int32 *height, int32 *depth,
							 int32 *format)
{
	*width = image->width;
	*height = image->height;
	// Keep opaque images opaque in RenderWare state. Treating every upload as
	// alpha-bearing enables blending and the extra GS alpha pass on world meshes.
	bool alpha = image->hasAlpha();
	*depth = alpha ? 32 : 24;
	*format = (alpha ? Raster::C8888 : Raster::C888) | type;
	return true;
}
bool32 rasterFromImage(Raster *raster, Image *image)
{
	bool lock = raster->pixels == nullptr;
	if (lock && !rasterLock(raster, 0, Raster::LOCKWRITE | Raster::LOCKNOFETCH))
		return false;
	if (image->width < raster->width || image->height < raster->height) {
		if (lock)
			rasterUnlock(raster, 0);
		return false;
	}
	Image *copy = Image::create(image->width, image->height, image->depth);
	copy->allocate();
	for (int y = 0; y < image->height; y++)
		memcpy(copy->pixels + y * copy->stride, image->pixels + y * image->stride,
			   image->width * image->bpp);
	if (image->palette)
		memcpy(copy->palette, image->palette, (1 << image->depth) * 4);
	copy->convertTo32();
	for (int y = 0; y < raster->height; y++)
		for (int x = 0; x < raster->width; x++) {
			uint8 *p = copy->pixels + y * copy->stride + x * 4;
			uint8 *out = raster->pixels + y * raster->stride + x * (raster->depth / 8);
			switch (raster->format & 0xF00) {
			case Raster::C888:
				memcpy(out, p, 3);
				break;
			case Raster::C1555:
			case Raster::C555:
				packPixel(out, p, raster->format & 0xF00);
				break;
			case Raster::C565:
				packPixel(out, p, Raster::C565);
				break;
			case Raster::C4444:
				packPixel(out, p, Raster::C4444);
				break;
			case Raster::LUM8:
				*out = p[0];
				break;
			default:
				memcpy(out, p, 4);
				break;
			}
		}
	copy->destroy();
	if (lock)
		rasterUnlock(raster, 0);
	return true;
}
Image *rasterToImage(Raster *raster)
{
	@autoreleasepool {
		RasterData *data = rasterData(raster);
		if (!data || raster->type == Raster::ZBUFFER)
			return nullptr;
		bool unlock = raster->pixels == nullptr;
		if (unlock && !rasterLock(raster, 0, Raster::LOCKREAD))
			return nullptr;
		Image *image = Image::create(raster->width, raster->height, 32);
		image->allocate();
		int f = raster->format & 0xF00, bpp = raster->depth / 8;
		for (int y = 0; y < image->height; y++)
			for (int x = 0; x < image->width; x++) {
				uint8 *p = raster->pixels + y * raster->stride + x * bpp,
					  *out = image->pixels + y * image->stride + x * 4;
				if (f == Raster::C888)
					conv_RGBA8888_from_RGB888(out, p);
				else if (f == Raster::LUM8) {
					out[0] = out[1] = out[2] = p[0];
					out[3] = 255;
				} else if (bpp == 2)
					unpack(out, p, f);
				else
					memcpy(out, p, 4);
			}
		if (unlock)
			rasterUnlock(raster, 0);
		return image;
	}
}
static Texture *portableTexture(Texture *texture)
{
	Raster *source = texture->raster;
	int levels = source->getNumLevels();
	Raster *raster = Raster::create(
		source->width, source->height, 32,
		Raster::TEXTURE | Raster::C8888 | (levels > 1 ? Raster::MIPMAP : 0), PLATFORM_D3D9);
	if (!raster)
		return nullptr;
	for (int i = 0; i < levels; i++) {
		if (!source->lock(i, Raster::LOCKREAD)) {
			raster->destroy();
			return nullptr;
		}
		Image *image = source->toImage();
		source->unlock(i);
		if (!image || !raster->lock(i, Raster::LOCKWRITE | Raster::LOCKNOFETCH)) {
			if (image)
				image->destroy();
			raster->destroy();
			return nullptr;
		}
		raster->setFromImage(image, PLATFORM_D3D9);
		raster->unlock(i);
		image->destroy();
	}
	Texture *out = Texture::create(raster);
	memcpy(out->name, texture->name, 32);
	memcpy(out->mask, texture->mask, 32);
	out->filterAddressing = texture->filterAddressing;
	return out;
}
void writeNativeTexture(Texture *texture, Stream *stream)
{
	Texture *portable = portableTexture(texture);
	if (!portable) {
		reportError("Could not export texture");
		return;
	}
	d3d9::writeNativeTexture(portable, stream);
	portable->destroy();
}
uint32 getSizeNativeTexture(Texture *texture)
{
	Texture *portable = portableTexture(texture);
	if (!portable)
		return 0;
	uint32 size = d3d9::getSizeNativeTexture(portable);
	portable->destroy();
	return size;
}
} // namespace metal
} // namespace rw
