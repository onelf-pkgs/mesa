# mesa

[Mesa](https://mesa3d.org) built for [onelf](https://github.com/QaidVoid/onelf)
packages: the GL and Vulkan drivers a bundle carries, so it draws on
hosts without a usable GL stack of their own, such as musl
distributions, containers and minimal virtual machines.

## What is different from a distribution's Mesa

- **No LLVM.** The AMD drivers compile shaders with ACO and the others
  never used LLVM, so the drivers carry none of it. The software
  renderer is softpipe: OpenGL 3.3 and slow, for hosts with no usable
  GPU. llvmpipe and lavapipe, the fast software renderers, need LLVM and
  are left out. LLVM and clang are used only while building, to compile
  the kernels some drivers carry.
- **Built on Void Linux**, whose official images cover x86_64 and
  aarch64, against glibc 2.41.
- **AMD GPUs on older kernels.** Mesa refuses kernels before 6.6 for
  radeonsi and radv; `patches/radeonsi-old-kernels.patch` drops that
  check, as pkgforge-dev's builds do, so such a host draws on its GPU
  instead of falling back to softpipe.
- **Compiled for size** (`-Os`), and stripped.
- **No zink.** Every GPU with a Vulkan driver here also has a native GL
  driver, so GL over Vulkan would never be chosen.
- **Only what draws.** No OpenCL, video decoding, ray tracing, layers or
  tools. `stubs/gen_perf.py` replaces the generator of Intel's
  performance counter tables, about 5 MB, so `GL_INTEL_performance_query`
  reports no counters.

| Architecture | Gallium | Vulkan |
|--------------|---------|--------|
| x86_64 | crocus, iris, nouveau, r600, radeonsi, softpipe, svga, virgl | amd, intel, intel_hasvk, virtio |
| aarch64 | asahi, etnaviv, freedreno, lima, nouveau, panfrost, radeonsi, softpipe, v3d, vc4, virgl | amd, asahi, broadcom, freedreno, panfrost, virtio |

## Releases

Tagged `v<mesa version>-<release>`, where `release` counts rebuilds of
the same Mesa. Each release carries, per architecture:

| Asset | Holds |
|-------|-------|
| `gl-<arch>.tar.zst` | the GL tree: `lib/` with the drivers and their libraries apart from glibc, `share/glvnd` |
| `gl-vulkan-<arch>.tar.zst` | the same with the Vulkan drivers, loader and `share/vulkan` |
| `gl-<arch>.onelf`, `gl-vulkan-<arch>.onelf` | each tree packed by `onelf sysroot pack-gl` |

The release notes list each `.onelf` with its BLAKE3, the hash a package
pins to fetch it at launch.

## Building

```sh
podman run --rm -v "$PWD:/src" -v "$(command -v onelf):/usr/local/bin/onelf:ro" -w /src \
  ghcr.io/void-linux/void-glibc:latest sh build.sh
```

Versions and hashes are in `package.toml`; the
[control repository](https://github.com/onelf-pkgs/.github) bumps them
when upstream releases.
