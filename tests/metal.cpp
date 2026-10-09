#include <rw.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <vector>
using namespace rw;
static GLFWwindow *window;
static Camera *camera;
static int checks;
static void require(bool ok, const char *message)
{
	if (!ok) {
		fprintf(stderr, "FAIL: %s\n", message);
		exit(1);
	}
	checks++;
}
static Camera *makeCamera(int width, int height)
{
	Camera *c = Camera::create();
	c->setFrame(Frame::create());
	c->frameBuffer = Raster::create(width, height, 32, Raster::CAMERATEXTURE | Raster::C8888);
	c->zBuffer = Raster::create(width, height, 32, Raster::ZBUFFER);
	c->setNearPlane(0.1f);
	c->setFarPlane(100);
	V2d vw = {0.5f, 0.5f};
	c->setViewWindow(&vw);
	require(c->frameBuffer && c->zBuffer, "camera allocation");
	return c;
}
static void destroyCamera(Camera *c)
{
	c->frameBuffer->destroy();
	c->zBuffer->destroy();
	Frame *f = c->getFrame();
	c->setFrame(nullptr);
	f->destroy();
	c->destroy();
}
static void begin(RGBA background = {0, 0, 0, 255})
{
	SetRenderState(VERTEXALPHA, 0);
	SetRenderState(ZTESTENABLE, 1);
	SetRenderState(ZWRITEENABLE, 1);
	SetRenderState(SRCBLEND, BLENDSRCALPHA);
	SetRenderState(DESTBLEND, BLENDINVSRCALPHA);
	SetRenderState(ALPHATESTFUNC, ALPHAALWAYS);
	SetRenderState(FOGENABLE, 0);
	SetRenderState(STENCILENABLE, 0);
	SetRenderState(GSALPHATEST, 0);
	SetRenderState(CULLMODE, CULLNONE);
	SetRenderStatePtr(TEXTURERASTER, nullptr);
	camera->clear(&background, Camera::CLEARIMAGE | Camera::CLEARZ | Camera::CLEARSTENCIL);
	camera->beginUpdate();
}
static void rect(RGBA color, float z = 0.5f, int x = 0, int y = 0, int w = 64, int h = 64)
{
	metal::Im2DVertex vertices[4] = {};
	for (int i = 0; i < 4; i++) {
		vertices[i].setScreenX(x + ((i == 1 || i == 2) ? w : 0));
		vertices[i].setScreenY(y + (i >= 2 ? h : 0));
		vertices[i].setScreenZ(z);
		vertices[i].setCameraZ(1);
		vertices[i].setColor(color.red, color.green, color.blue, color.alpha);
		vertices[i].setU((i == 1 || i == 2) ? 1 : 0, 1);
		vertices[i].setV(i >= 2 ? 1 : 0, 1);
	}
	im2d::RenderPrimitive(PRIMTYPETRIFAN, vertices, 4);
}
static Image *snapshot(void)
{
	camera->endUpdate();
	Image *image = camera->frameBuffer->toImage();
	require(image != nullptr, "framebuffer readback");
	require(metal::waitIdle(), "Metal command completed successfully");
	return image;
}
static void pixel(Image *image, int x, int y, int r, int g, int b, const char *message,
				  int tolerance = 2)
{
	uint8 *p = image->pixels + y * image->stride + x * 4;
	if (abs(p[0] - r) > tolerance || abs(p[1] - g) > tolerance || abs(p[2] - b) > tolerance)
		fprintf(stderr, "pixel %d,%d = %d,%d,%d; expected %d,%d,%d\n", x, y, p[0], p[1], p[2], r, g,
				b);
	require(abs(p[0] - r) <= tolerance && abs(p[1] - g) <= tolerance && abs(p[2] - b) <= tolerance,
			message);
}
static Texture *texture(RGBA color)
{
	Image *image = Image::create(2, 2, 32);
	image->allocate();
	for (int i = 0; i < 4; i++)
		memcpy(image->pixels + i * 4, &color, 4);
	Texture *t = Texture::create(Raster::createFromImage(image));
	image->destroy();
	t->setFilter(Texture::NEAREST);
	t->setAddressU(Texture::CLAMP);
	t->setAddressV(Texture::CLAMP);
	return t;
}
static void renderStates(void)
{
	begin();
	rect({255, 0, 0, 255}, 0.2f);
	rect({0, 0, 255, 255}, 0.7f);
	Image *image = snapshot();
	pixel(image, 32, 32, 255, 0, 0, "depth rejects farther fragments");
	image->destroy();
	begin();
	SetRenderState(ZWRITEENABLE, 0);
	rect({255, 0, 0, 255}, 0.2f);
	SetRenderState(ZWRITEENABLE, 1);
	rect({0, 0, 255, 255}, 0.7f);
	image = snapshot();
	pixel(image, 32, 32, 0, 0, 255, "depth writes can be disabled");
	image->destroy();
	begin();
	SetRenderState(VERTEXALPHA, 1);
	rect({255, 0, 0, 128});
	image = snapshot();
	pixel(image, 32, 32, 128, 0, 0, "alpha blending");
	image->destroy();
	begin();
	SetRenderState(VERTEXALPHA, 1);
	SetRenderState(ALPHATESTFUNC, ALPHAGREATEREQUAL);
	SetRenderState(ALPHATESTREF, 200);
	rect({255, 0, 0, 128});
	image = snapshot();
	pixel(image, 32, 32, 0, 0, 0, "alpha test discards fragments");
	image->destroy();
	begin();
	SetRenderState(TEXTUREADDRESS, Texture::CLAMP);
	require(GetRenderState(TEXTUREADDRESSU) == Texture::CLAMP &&
				GetRenderState(TEXTUREADDRESSV) == Texture::CLAMP,
			"texture address alias");
	metal::setScissor(20, 20, 10, 10);
	rect({255, 0, 0, 255});
	metal::disableScissor();
	image = snapshot();
	pixel(image, 25, 25, 255, 0, 0, "scissor interior");
	pixel(image, 15, 25, 0, 0, 0, "scissor exterior");
	image->destroy();
	begin();
	SetRenderState(STENCILENABLE, 1);
	SetRenderState(STENCILFUNCTION, STENCILALWAYS);
	SetRenderState(STENCILPASS, STENCILREPLACE);
	SetRenderState(STENCILFUNCTIONREF, 1);
	rect({255, 0, 0, 255}, 0.5f, 0, 0, 32, 64);
	SetRenderState(STENCILPASS, STENCILKEEP);
	SetRenderState(STENCILFUNCTION, STENCILEQUAL);
	rect({0, 255, 0, 255});
	image = snapshot();
	pixel(image, 16, 32, 0, 255, 0, "stencil accepts marked pixels");
	pixel(image, 48, 32, 0, 0, 0, "stencil rejects unmarked pixels");
	image->destroy();
}
static void subrasters(void)
{
	begin({0, 0, 255, 255});
	camera->endUpdate();
	Camera *sub = Camera::create();
	sub->setFrame(Frame::create());
	sub->frameBuffer = Raster::create(0, 0, 0, Raster::CAMERATEXTURE | Raster::DONTALLOCATE);
	sub->zBuffer = Raster::create(0, 0, 0, Raster::ZBUFFER | Raster::DONTALLOCATE);
	Rect area = {16, 16, 16, 16};
	sub->frameBuffer->subRaster(camera->frameBuffer, &area);
	sub->zBuffer->subRaster(camera->zBuffer, &area);
	RGBA red = {255, 0, 0, 255};
	sub->clear(&red, Camera::CLEARIMAGE | Camera::CLEARZ | Camera::CLEARSTENCIL);
	Image *image = snapshot();
	pixel(image, 20, 20, 255, 0, 0, "subraster clear interior");
	pixel(image, 4, 4, 0, 0, 255, "subraster clear preserves parent");
	image->destroy();
	image = sub->frameBuffer->toImage();
	require(image && image->width == 16 && image->height == 16, "subraster readback dimensions");
	pixel(image, 2, 2, 255, 0, 0, "subraster readback content");
	image->destroy();
	destroyCamera(sub);
	Raster *copy = Raster::create(64, 64, 32, Raster::TEXTURE | Raster::C8888);
	Raster::pushContext(copy);
	require(camera->frameBuffer->renderFast(0, 0), "GPU raster copy");
	Raster::popContext();
	image = copy->toImage();
	pixel(image, 20, 20, 255, 0, 0, "GPU copy preserves subraster pixels");
	pixel(image, 4, 4, 0, 0, 255, "GPU copy preserves parent pixels");
	image->destroy();
	copy->destroy();
	begin();
	rect({0, 255, 0, 255});
	image = snapshot();
	pixel(image, 20, 20, 0, 255, 0, "camera resumes after subraster pass");
	image->destroy();
}
static void immediate3D(void)
{
	metal::Im3DVertex v[3] = {};
	V3d positions[] = {{-0.6f, -0.6f, 2}, {0.6f, -0.6f, 2}, {0, 0.6f, 2}};
	for (int i = 0; i < 3; i++) {
		v[i].position = positions[i];
		v[i].setColor(255, 0, 0, 128);
	}
	begin();
	SetRenderState(VERTEXALPHA, 1);
	im3d::Transform(v, 3, nullptr, im3d::ALLOPAQUE);
	im3d::RenderPrimitive(PRIMTYPETRILIST);
	im3d::End();
	Image *image = snapshot();
	pixel(image, 32, 32, 128, 0, 0, "immediate 3D preserves vertex alpha");
	image->destroy();
	begin();
	SetRenderState(ZTESTENABLE, 0);
	rect({255, 0, 0, 255}, 0.1f);
	SetRenderState(ZTESTENABLE, 1);
	rect({0, 0, 255, 255}, 0.9f);
	image = snapshot();
	pixel(image, 32, 32, 0, 0, 255, "disabled depth test also disables depth writes");
	image->destroy();
	Raster *depth = camera->zBuffer;
	camera->zBuffer = nullptr;
	begin();
	rect({0, 255, 0, 255});
	image = snapshot();
	pixel(image, 32, 32, 0, 255, 0, "camera without a depth attachment");
	image->destroy();
	camera->zBuffer = depth;
}

static void textures(void)
{
	Image *image = Image::create(2, 2, 32);
	image->allocate();
	RGBA colors[] = {{255, 0, 0, 255}, {0, 255, 0, 255}, {0, 0, 255, 255}, {255, 255, 255, 255}};
	memcpy(image->pixels, colors, sizeof(colors));
	Raster *raster = Raster::createFromImage(image);
	image->destroy();
	require(raster != nullptr, "texture creation");
	begin();
	SetRenderStatePtr(TEXTURERASTER, raster);
	SetRenderState(TEXTUREFILTER, Texture::NEAREST);
	SetRenderState(TEXTUREADDRESSU, Texture::CLAMP);
	SetRenderState(TEXTUREADDRESSV, Texture::CLAMP);
	rect({255, 255, 255, 255});
	image = snapshot();
	pixel(image, 16, 16, 255, 0, 0, "texture top left");
	pixel(image, 48, 16, 0, 255, 0, "texture top right");
	pixel(image, 16, 48, 0, 0, 255, "texture bottom left");
	pixel(image, 48, 48, 255, 255, 255, "texture bottom right");
	image->destroy();
	// Exercise the existing D3D9 on-disk TXD format with a Metal source texture.
	Texture *t = Texture::create(raster);
	strcpy(t->name, "metal-roundtrip");
	TexDictionary *dictionary = TexDictionary::create();
	dictionary->add(t);
	std::vector<uint8> bytes(dictionary->streamGetSize() + 12);
	StreamMemory stream;
	stream.open(bytes.data(), 0, bytes.size());
	dictionary->streamWrite(&stream);
	uint32 length = stream.length;
	stream.seek(0, 0);
	require(findChunk(&stream, ID_TEXDICTIONARY, nullptr, nullptr), "TXD export header");
	TexDictionary *loaded = TexDictionary::streamRead(&stream);
	require(loaded != nullptr, "TXD reimport");
	Texture *reimported = loaded->find("metal-roundtrip");
	require(reimported != nullptr, "TXD preserves texture name");
	require(reimported->raster->platform == PLATFORM_D3D9, "TXD uses established portable format");
	Raster *converted = Raster::convertTexToCurrentPlatform(reimported->raster);
	reimported->raster = converted;
	image = converted->toImage();
	pixel(image, 0, 0, 255, 0, 0, "TXD preserves pixels");
	image->destroy();
	require(length > 100, "TXD contains pixel data");
	// The backend also converts foreign native rasters when binding a material texture.
	reimported->raster = Raster::convertTexToCurrentPlatform(reimported->raster);
	loaded->destroy();
	dictionary->destroy();
	stream.close();
	int formats[] = {Raster::C8888, Raster::C888,  Raster::C1555, Raster::C555,
					 Raster::C565,	Raster::C4444, Raster::LUM8};
	for (int format : formats) {
		Raster *r = Raster::create(4, 4, 0, Raster::TEXTURE | format);
		image = Image::create(4, 4, 32);
		image->allocate();
		for (int i = 0; i < 16; i++) {
			image->pixels[i * 4] = 255;
			image->pixels[i * 4 + 1] = 0;
			image->pixels[i * 4 + 2] = 0;
			image->pixels[i * 4 + 3] = 255;
		}
		require(r->setFromImage(image) != nullptr, "upload pixel format");
		image->destroy();
		image = r->toImage();
		pixel(image, 1, 1, 255, format == Raster::LUM8 ? 255 : 0, format == Raster::LUM8 ? 255 : 0,
			  "pixel format roundtrip");
		image->destroy();
		r->destroy();
	}
	Raster *mip = Raster::create(
		8, 8, 32, Raster::TEXTURE | Raster::C8888 | Raster::MIPMAP | Raster::AUTOMIPMAP);
	image = Image::create(8, 8, 32);
	image->allocate();
	for (int i = 0; i < 64; i++)
		memcpy(image->pixels + i * 4, &colors[1], 4);
	mip->setFromImage(image);
	image->destroy();
	require(mip->getNumLevels() == 4, "mipmap count");
	require(mip->lock(3, Raster::LOCKREAD) != nullptr, "read generated mip");
	image = mip->toImage();
	pixel(image, 0, 0, 0, 255, 0, "generated mip content");
	image->destroy();
	mip->unlock(3);
	mip->destroy();
}
static Atomic *triangle(uint32 extraFlags = 0)
{
	Geometry *geo = Geometry::create(3, 1, Geometry::POSITIONS | Geometry::MODULATE | extraFlags);
	V3d points[] = {{-0.6f, -0.6f, 2}, {0.6f, -0.6f, 2}, {0, 0.6f, 2}};
	memcpy(geo->morphTargets[0].vertices, points, sizeof(points));
	if (extraFlags & Geometry::NORMALS)
		for (int i = 0; i < 3; i++)
			geo->morphTargets[0].normals[i] = {0, 0, -1};
	geo->triangles[0] = {{0, 1, 2}, 0};
	Material *m = Material::create();
	m->color = {255, 0, 0, 255};
	geo->matList.appendMaterial(m);
	m->destroy();
	geo->calculateBoundingSphere();
	geo->unlock();
	Atomic *a = Atomic::create();
	a->setFrame(Frame::create());
	a->setGeometry(geo, 0);
	geo->destroy();
	return a;
}
static void destroyAtomic(Atomic *a)
{
	Frame *f = a->getFrame();
	a->setFrame(nullptr);
	a->destroy();
	f->destroy();
}
static void foreignTexture(void)
{
	Atomic *a = triangle(Geometry::TEXTURED);
	Image *image = Image::create(2, 2, 32);
	image->allocate();
	RGBA blue = {0, 0, 255, 255};
	for (int i = 0; i < 4; i++)
		memcpy(image->pixels + i * 4, &blue, 4);
	Raster *raster = Raster::create(2, 2, 32, Raster::TEXTURE | Raster::C8888, PLATFORM_D3D9);
	raster->setFromImage(image, PLATFORM_D3D9);
	image->destroy();
	Texture *tex = Texture::create(raster);
	tex->setFilter(Texture::NEAREST);
	a->geometry->matList.materials[0]->color = {255, 255, 255, 255};
	a->geometry->matList.materials[0]->setTexture(tex);
	begin();
	a->render();
	image = snapshot();
	pixel(image, 32, 32, 0, 0, 255, "foreign TXD texture converts when bound");
	image->destroy();
	require(tex->raster->platform == PLATFORM_METAL, "foreign material texture gets Metal storage");
	destroyAtomic(a);
	tex->destroy();
}
static void gsAlpha(void)
{
	Atomic *a = triangle();
	Material *m = a->geometry->matList.materials[0];
	for (int alpha : {64, 128}) {
		V3d zero = {0, 0, 0};
		a->getFrame()->translate(&zero, COMBINEREPLACE);
		m->color = {255, 0, 0, uint8(alpha)};
		begin();
		SetRenderState(GSALPHATEST, 1);
		SetRenderState(GSALPHATESTREF, 128);
		a->render();
		m->color = {0, 0, 255, 255};
		V3d offset = {0, 0, 1};
		a->getFrame()->translate(&offset, COMBINEREPLACE);
		a->render();
		Image *image = snapshot();
		if (alpha == 64)
			pixel(image, 32, 32, 0, 0, 255, "GS low alpha preserves depth for farther geometry");
		else
			pixel(image, 32, 32, 128, 0, 0, "GS high alpha writes depth");
		image->destroy();
	}
	destroyAtomic(a);
}
static void nativeGeometry(void)
{
	Atomic *a = triangle();
	auto source = d3d9::makeDefaultPipeline();
	source->instance(a);
	source->destroy();
	a->geometry->flags |= Geometry::NATIVE;
	std::vector<uint8> bytes(a->geometry->streamGetSize() + 12);
	StreamMemory stream;
	stream.open(bytes.data(), 0, bytes.size());
	a->geometry->streamWrite(&stream);
	stream.seek(0, 0);
	require(findChunk(&stream, ID_GEOMETRY, nullptr, nullptr), "native DFF geometry export");
	Geometry *geo = Geometry::streamRead(&stream);
	require(geo && geo->flags & Geometry::NATIVE, "native geometry import");
	a->setGeometry(geo, 0);
	geo->destroy();
	begin();
	a->render();
	Image *image = snapshot();
	pixel(image, 32, 32, 255, 0, 0, "native D3D9 geometry converts and renders");
	image->destroy();
	require(a->geometry->instData->platform == PLATFORM_METAL,
			"native geometry becomes Metal resources");
	destroyAtomic(a);
}
static void lighting(void)
{
	World *world = World::create();
	world->addCamera(camera);
	Light *ambient = Light::create(Light::AMBIENT);
	ambient->setColor(0, 0.2f, 0);
	world->addLight(ambient);
	Light *direct = Light::create(Light::DIRECTIONAL);
	direct->setColor(0.6f, 0, 0);
	direct->setFrame(Frame::create());
	world->addLight(direct);
	Atomic *a = triangle(Geometry::LIGHT | Geometry::NORMALS);
	a->geometry->matList.materials[0]->color = {255, 255, 255, 255};
	a->geometry->matList.materials[0]->surfaceProps = {1, 1, 1};
	begin();
	a->render();
	Image *image = snapshot();
	pixel(image, 32, 32, 153, 51, 0, "ambient and directional lighting");
	image->destroy();
	camera->fogPlane = 0;
	camera->setFarPlane(4);
	begin();
	SetRenderState(FOGENABLE, 1);
	SetRenderState(FOGCOLOR, 0x0000FFFF);
	a->render();
	image = snapshot();
	pixel(image, 32, 32, 77, 26, 128, "fog mixes with lit geometry", 3);
	image->destroy();
	camera->fogPlane = 1;
	camera->setFarPlane(100);
	world->removeLight(direct);
	Frame *f = direct->getFrame();
	direct->setFrame(nullptr);
	direct->destroy();
	f->destroy();
	world->removeLight(ambient);
	ambient->destroy();
	world->removeCamera(camera);
	world->destroy();
	engine->currentWorld = nullptr;
	destroyAtomic(a);
}
static void pipelines(void)
{
	Atomic *a = triangle();
	begin();
	a->render();
	Image *image = snapshot();
	pixel(image, 32, 32, 255, 0, 0, "default geometry pipeline");
	image->destroy();
	Geometry *geo = a->geometry;
	begin();
	a->render();
	geo->lock(Geometry::LOCKVERTICES);
	for (int i = 0; i < 3; i++)
		geo->morphTargets[0].vertices[i].x += 0.8f;
	geo->unlock();
	a->render();
	image = snapshot();
	pixel(image, 32, 32, 255, 0, 0, "reinstance preserves previously encoded draw");
	pixel(image, 8, 32, 255, 0, 0, "reinstance uses new vertex buffer");
	image->destroy();
	for (int i = 0; i < 3; i++)
		geo->morphTargets[0].vertices[i].x -= 0.8f;
	geo->lock(Geometry::LOCKVERTICES);
	geo->unlock();
	geo->lock(Geometry::LOCKVERTICES);
	for (int i = 0; i < 3; i++)
		geo->morphTargets[0].vertices[i].x += 0.8f;
	geo->unlock();
	begin();
	a->render();
	image = snapshot();
	pixel(image, 32, 32, 0, 0, 0, "geometry reinstance updates vertices");
	pixel(image, 8, 32, 255, 0, 0, "updated vertices visible");
	image->destroy();
	for (int i = 0; i < 3; i++)
		geo->morphTargets[0].vertices[i].x -= 0.8f;
	geo->lock(Geometry::LOCKVERTICES);
	geo->unlock();
	Skin *skin = rwNewT(Skin, 1, MEMDUR_EVENT);
	memset(skin, 0, sizeof(Skin));
	skin->init(1, 1, 3);
	RawMatrix identity;
	Matrix ident;
	ident.setIdentity();
	convMatrix(&identity, &ident);
	memcpy(skin->inverseMatrices, &identity, 64);
	memset(skin->weights, 0, 3 * 4 * sizeof(float));
	memset(skin->indices, 0, 3 * 4);
	for (int i = 0; i < 3; i++) {
		skin->weights[i * 4] = 1;
		skin->indices[i * 4] = 0;
	}
	Skin::set(geo, skin);
	a->pipeline = skinGlobals.pipelines[PLATFORM_METAL];
	geo->lock(Geometry::LOCKVERTICES);
	geo->unlock();
	Matrix pose;
	pose.setIdentity();
	HAnimHierarchy hierarchy = {};
	hierarchy.flags = HAnimHierarchy::LOCALSPACEMATRICES;
	hierarchy.numNodes = 1;
	hierarchy.matrices = &pose;
	Skin::setHierarchy(a, &hierarchy);
	begin();
	a->render();
	image = snapshot();
	pixel(image, 32, 32, 255, 0, 0, "skin identity pose");
	image->destroy();
	pose.pos.x = 0.8f;
	begin();
	a->render();
	image = snapshot();
	pixel(image, 32, 32, 0, 0, 0, "skin pose moves geometry");
	pixel(image, 8, 32, 255, 0, 0, "skin transformed vertex location");
	image->destroy();
	pose.setIdentity();
	Skin::setHierarchy(a, nullptr);
	Material *m = geo->matList.materials[0];
	m->color = {0, 0, 0, 255};
	Texture *env = texture({0, 255, 0, 255});
	MatFX::setEffects(m, MatFX::ENVMAP);
	MatFX *fx = MatFX::get(m);
	fx->setEnvTexture(env);
	fx->setEnvCoefficient(1);
	fx->setEnvFBAlpha(0);
	MatFX::envMapApplyLight = false;
	MatFX::envMapUseMatColor = false;
	MatFX::enableEffects(a);
	begin();
	a->render();
	image = snapshot();
	pixel(image, 32, 32, 0, 255, 0, "environment mapping pipeline");
	image->destroy();
	destroyAtomic(a);
	env->destroy();
}
static void videoModes(void)
{
	int count = Engine::getNumVideoModes();
	require(count > 1, "windowed and fullscreen video modes");
	require(Engine::getCurrentVideoMode() == 0, "default windowed video mode");
	VideoMode mode = {};
	require(Engine::getVideoModeInfo(&mode, 0) != nullptr && mode.width == 64 &&
			mode.height == 64 && mode.depth == 32 && mode.flags == 0,
			"windowed mode retains requested dimensions");
	const GLFWvidmode *desktop = glfwGetVideoMode(glfwGetPrimaryMonitor());
	require(desktop && Engine::getVideoModeInfo(&mode, 1) != nullptr &&
			mode.width == desktop->width && mode.height == desktop->height &&
			mode.flags == VIDEOMODEEXCLUSIVE, "current scaled desktop is a fullscreen mode");
	for (int i = 1; i < count; i++) {
		require(Engine::getVideoModeInfo(&mode, i) != nullptr && mode.width > 0 &&
				mode.height > 0 && mode.depth == 32 && mode.flags == VIDEOMODEEXCLUSIVE,
				"fullscreen mode properties");
	}
	require(Engine::setVideoMode(count - 1) && Engine::getCurrentVideoMode() == count - 1,
			"select fullscreen mode before start");
	require(!Engine::setVideoMode(-1) && !Engine::setVideoMode(count) &&
			Engine::getCurrentVideoMode() == count - 1, "invalid mode preserves selection");
	require(Engine::getVideoModeInfo(&mode, -1) == nullptr &&
			Engine::getVideoModeInfo(&mode, count) == nullptr, "invalid video mode queries");
	require(Engine::setVideoMode(0), "restore windowed mode for pixel tests");
}

int main(int argc, char **argv)
{
	require(Engine::init(), "engine init");
	registerMeshPlugin();
	registerNativeDataPlugin();
	registerSkinPlugin();
	registerHAnimPlugin();
	registerMatFXPlugin();
	EngineOpenParams params = {&window, 64, 64, "librw Metal tests"};
	require(Engine::open(&params), "engine open");
	videoModes();
	int samples = argc > 1 ? atoi(argv[1]) : 1;
	require(Engine::getMaxMultiSamplingLevels() >= uint32(samples), "sample count supported");
	require(Engine::setMultiSamplingLevels(samples), "set sample count before start");
	glfwWindowHint(GLFW_VISIBLE, GLFW_FALSE);
	require(Engine::start(), "engine start");
	require(glfwGetWindowMonitor(window) == nullptr, "windowed mode creates windowed surface");
	require(!Engine::setVideoMode(1), "video mode changes require engine restart");
	printf("Native Metal tests on %s\n", metal::getDeviceName());
	camera = makeCamera(64, 64);
	renderStates();
	immediate3D();
	textures();
	pipelines();
	subrasters();
	lighting();
	nativeGeometry();
	foreignTexture();
	gsAlpha();
	destroyCamera(camera);
	require(metal::waitIdle(), "final GPU completion");
	Engine::stop();
	Engine::close();
	Engine::term();
	printf("PASS: %d checks\n", checks);
	return 0;
}
