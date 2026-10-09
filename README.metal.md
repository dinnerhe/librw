# Native Metal on macOS

Select `LIBRW_PLATFORM=METAL` to use Apple's Metal API directly. The backend is
Objective-C++ with Metal Shading Language shaders. GLFW supplies the Cocoa window
and input; a `CAMetalLayer` presents frames. It has no Vulkan, MoltenVK, or OpenGL
rendering dependency.

## Build and view a DFF

Install Xcode or the Command Line Tools, CMake, and GLFW. If you use Homebrew:

```sh
brew install cmake glfw
cmake -S . -B build-metal -DLIBRW_PLATFORM=METAL -DCMAKE_BUILD_TYPE=Release
cmake --build build-metal --parallel
./build-metal/tools/clumpview/clumpview tools/playground/files/teapot.dff
```

Run these commands from the repository root. For a textured model, either give a
TXD after the DFF or supply a directory containing the named texture images:

```sh
./build-metal/tools/clumpview/clumpview model.dff textures.txd
./build-metal/tools/clumpview/clumpview -i tools/camera/files/clump/ tools/camera/files/clump.dff
```

Left drag orbits, middle drag pans, and the wheel zooms. `F` frames the model,
`Tab` changes between orbit and fly controls, and `Esc` exits. Model coordinates
are used as supplied; the viewer assumes Z is up.

For a repeatable frame capture with Metal API validation:

```sh
MTL_DEBUG_LAYER=1 ./build-metal/tools/clumpview/clumpview \
  -n 5 -s /tmp/metal-teapot.png tools/playground/files/teapot.dff
```

`-n` exits after the requested number of frames. `-s` writes a PNG from the
rendered framebuffer and defaults to five frames if `-n` is omitted. Captures
include the viewer UI. The viewer prints the native GPU name and model counts.

## Rendering support

- Default geometry, prelighting, ambient/directional/point/spot lighting, fog,
  and geometry updates.
- Skeletal skinning using HAnim matrices, including local and world space poses.
- Environment mapping through the MatFX pipeline, including its RenderWare
  material/color and framebuffer alpha options.
- Indexed and nonindexed immediate 2D/3D points, lines, strips, triangles, and
  triangle fans. Fans are expanded into triangle indices.
- Blending, depth, culling, stencil, alpha testing, and the PS2 GS alpha behavior.
- Camera textures, subrasters, clipped clears, Retina viewport scaling, UI
  scissoring, and GPU raster copying.
- Device-supported MSAA sample counts. Set the sample count through
  `Engine::setMultiSamplingLevels` after `Engine::open` and before `Engine::start`.
- Windowed and primary-monitor fullscreen video modes, selected while the
  engine is open and applied at startup. Mode changes require an engine restart.
  The current scaled desktop resolution is included even when GLFW's fullscreen
  enumeration omits it on macOS.
- Texture/image upload and readback, mipmaps, sampling modes, and common
  RenderWare pixel formats. Palettized and compressed source textures are
  decoded through the existing image conversion code. GPU storage is RGBA8.
- Native source geometry is unpacked through the existing platform modules
  before being uploaded to Metal. Their format support limits still apply.
- Metal texture dictionaries export as standard D3D9 TXD data, including mip
  levels, so assets do not require a new Metal-specific file format. Uninstance
  explicitly instanced Metal geometry before exporting a DFF.

The renderer caches pipeline, depth/stencil, and sampler state. Up to three
command buffers can be in flight. Draw commands retain resources, and geometry
updates replace buffers so they cannot overwrite an earlier draw's data. CPU
texture writes and readbacks synchronize with submitted GPU work. Texture writes
can therefore stall the queue; frequent per-frame texture editing will need
further optimization.

CMake is the supported build path for Metal. Runtime verification was performed
on Apple M2 hardware; the managed-storage path for Intel Macs has not been run
on Intel hardware. Material effects beyond environment mapping and depth-buffer
readback are not implemented.

## GPU integration tests

These tests execute real Metal commands and check the resulting pixels. Run them
in a macOS desktop session with a Metal-capable GPU:

```sh
cmake -S . -B build-metal -DLIBRW_PLATFORM=METAL -DLIBRW_METAL_TESTS=ON
cmake --build build-metal --parallel
ctest --test-dir build-metal --output-on-failure
```

CTest enables Metal API validation and runs the same suite with one sample and
4× MSAA. It checks depth, blending, alpha tests, stencil, scissoring, texture
orientation and formats, mipmaps, TXD round trips, default/native DFF geometry,
geometry buffer replacement, skin poses, environment mapping, lighting, fog,
subcamera clears/readback, GPU raster copying, and video-mode selection.

To embed librw, use `librw::librw` from CMake. Public headers remain C++ and do not
require Objective-C++. `rw::metal::waitIdle()` waits for GPU work and returns false
if a command failed; `rw::metal::getDeviceName()` identifies the selected GPU.
