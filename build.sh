#!/bin/sh
# Builds Mesa for this machine's architecture into dist/:
#
#   gl-<arch>.tar.zst, gl-<arch>.onelf                GL drivers
#   gl-vulkan-<arch>.tar.zst, gl-vulkan-<arch>.onelf  GL and Vulkan drivers
#
# Each tarball is a GL tree as `onelf sysroot pack-gl` takes it: lib/
# with the drivers and every library they need apart from glibc, and the
# glvnd and Vulkan manifests under share/. Each .onelf is that tree
# packed, with its BLAKE3 in a .blake3 beside it.
#
# Usage: build.sh
#
# Runs as root in a Void Linux (glibc) container with this directory as
# the working directory. ONELF names an onelf binary to use instead of
# the pinned release.
set -eu
cd "$(dirname "$0")"

arch=$(uname -m)
onelf_version=0.4.2
case $arch in
x86_64)
    gallium=crocus,iris,nouveau,r600,radeonsi,softpipe,svga,virgl
    vulkan=amd,intel,intel_hasvk,virtio
    onelf_sha256=65121bb1abebed95191615218a4a5c6fdb97a410d8625d6ebc2fce3c09881dd6
    ;;
aarch64)
    gallium=asahi,etnaviv,freedreno,lima,nouveau,panfrost,radeonsi,softpipe,v3d,vc4,virgl
    vulkan=amd,asahi,broadcom,freedreno,panfrost,virtio
    onelf_sha256=ae0d80d206b2fbbefda122c0a17a543a18c40557a58847090a03722113a2410f
    ;;
*)
    echo "unsupported architecture: $arch" >&2
    exit 1
    ;;
esac

xbps-install -Syu xbps > /dev/null
xbps-install -Syu > /dev/null
xbps-install -y \
    base-devel cmake meson ninja pkg-config python3 python3-Mako \
    python3-packaging python3-ply python3-yaml bison flex glslang \
    llvm21-devel clang21-devel libclc SPIRV-LLVM-Translator-devel SPIRV-Tools-devel \
    expat-devel zlib-devel libzstd-devel elfutils-devel libdrm-devel \
    libglvnd-devel wayland-devel wayland-protocols libX11-devel \
    libxcb-devel libXext-devel libXfixes-devel libXrandr-devel \
    libxshmfence-devel libXxf86vm-devel xcb-util-keysyms-devel \
    Vulkan-Headers vulkan-loader-devel curl findutils patch tar xz zstd > /dev/null

toml() {
    python3 -c '
import sys, tomllib
value = tomllib.load(open("package.toml", "rb"))
for key in sys.argv[1].split("."):
    value = value[key]
print(value)
' "$1"
}

# fetch <source>: download a source into build/src once, and check it.
fetch() {
    version=$(toml "sources.$1.version")
    url=$(toml "sources.$1.url" | sed "s/{version}/$version/g")
    file=build/src/${url##*/}
    mkdir -p build/src
    if [ ! -f "$file" ]; then
        curl -fL --retry 3 -o "$file.part" "$url"
        mv "$file.part" "$file"
    fi
    echo "$(toml "sources.$1.sha256")  $file" | sha256sum -c - > /dev/null
    echo "$file"
}

work=$PWD/build/work
jobs=${JOBS:-$(nproc)}

mesa_source=$(fetch mesa)
rm -rf "$work/mesa" "$work/host" "$work/build" "$work/stage" "$work/tools"
mkdir -p "$work/mesa"
tar -xJf "$mesa_source" -C "$work/mesa" --strip-components=1
for p in patches/*.patch; do
    patch -d "$work/mesa" -p1 --forward --quiet < "$p"
done
cp stubs/gen_perf.py "$work/mesa/src/intel/perf/gen_perf.py"

# The drivers' OpenCL kernels are compiled by mesa_clc and vtn_bindgen2,
# which need clang. They are built first against the distribution's LLVM
# and only run during the build; the drivers carry no LLVM.
meson setup "$work/host" "$work/mesa" \
    --prefix="$work/tools" \
    -D gallium-drivers= -D vulkan-drivers= -D platforms= \
    -D glx=disabled -D egl=disabled -D gbm=disabled -D glvnd=disabled \
    -D llvm=enabled -D shared-llvm=enabled \
    -D mesa-clc=enabled -D install-mesa-clc=true \
    -D precomp-compiler=enabled -D install-precomp-compiler=true \
    -D build-tests=false -D html-docs=disabled
meson compile -C "$work/host" -j "$jobs"
meson install -C "$work/host" --quiet
PATH="$work/tools/bin:$PATH"

meson setup "$work/build" "$work/mesa" \
    --prefix=/usr --libdir=lib -D optimization=s -D debug=false \
    -D b_ndebug=true -D b_lto=false \
    -D platforms=x11,wayland \
    -D gallium-drivers="$gallium" \
    -D vulkan-drivers="$vulkan" \
    -D vulkan-layers= \
    -D vulkan-manifest-per-architecture=false \
    -D glx=dri -D egl=enabled -D gbm=enabled -D glvnd=enabled \
    -D gles1=disabled -D gles2=enabled \
    -D llvm=disabled \
    -D mesa-clc=system -D precomp-compiler=system \
    -D gallium-va=disabled -D gallium-rusticl=false -D video-codecs= \
    -D intel-rt=disabled -D microsoft-clc=disabled -D teflon=false \
    -D valgrind=disabled -D libunwind=disabled -D lmsensors=disabled \
    -D android-libbacktrace=disabled \
    -D tools= -D build-tests=false -D html-docs=disabled
meson compile -C "$work/build" -j "$jobs"
DESTDIR="$work/stage" meson install -C "$work/build" --quiet

# glibc stays with the package that uses the build; everything else a
# library in the tree needs is copied in.
is_glibc() {
    case $1 in
    ld-linux*.so.* | libc.so.* | libm.so.* | libmvec.so.* | libpthread.so.* | \
        libdl.so.* | librt.so.* | libresolv.so.* | libutil.so.* | libanl.so.*)
        return 0
        ;;
    esac
    return 1
}

set -- /usr/lib/ld-linux-*.so.*
loader=$1

# close <tree>: copy into <tree>/lib every library its objects need.
close() {
    while :; do
        added=0
        find "$1/lib" -name '*.so*' -type f > "$work/objects"
        while read -r object; do
            "$loader" --library-path "$1/lib:/usr/lib" --list "$object" > "$work/list"
            awk '$2 == "=>" && $3 ~ /^\// { print $1, $3 }' "$work/list" > "$work/needs"
            while read -r soname path; do
                if is_glibc "$soname" || [ -e "$1/lib/$soname" ]; then
                    continue
                fi
                cp -L "$path" "$1/lib/$soname"
                added=1
            done < "$work/needs"
        done < "$work/objects"
        [ "$added" -eq 1 ] || break
    done
}

# tree <name> <vulkan>: assemble a GL tree, with Vulkan when <vulkan> is 1.
tree() {
    dir=$work/$1-tree
    rm -rf "$dir"
    mkdir -p "$dir/lib" "$dir/share"
    cp -a "$work/stage/usr/lib/." "$dir/lib/"
    rm -rf "$dir/lib/pkgconfig"
    cp -a "$work/stage/usr/share/glvnd" "$dir/share/"
    for lib in libEGL.so.1 libGL.so.1 libGLX.so.0 libGLdispatch.so.0 libOpenGL.so.0 libGLESv2.so.2; do
        cp -L "/usr/lib/$lib" "$dir/lib/$lib"
    done
    if [ "$2" -eq 1 ]; then
        cp -a "$work/stage/usr/share/vulkan" "$dir/share/"
        cp -L /usr/lib/libvulkan.so.1 "$dir/lib/libvulkan.so.1"
    else
        rm -f "$dir"/lib/libvulkan_*.so
    fi
    close "$dir"
    find "$dir/lib" -name '*.so*' -type f -exec strip --strip-unneeded {} +
    tar --zstd -cf "dist/$1-$arch.tar.zst" --sort=name --owner=0 --group=0 \
        -C "$dir" .
}

if [ -n "${ONELF:-}" ]; then
    onelf=$ONELF
else
    onelf=build/tools/onelf-$onelf_version-$arch
    if [ ! -x "$onelf" ]; then
        mkdir -p build/tools
        curl -fL --retry 3 -o "$onelf.part" \
            "https://github.com/QaidVoid/onelf/releases/download/$onelf_version/onelf-$arch-linux"
        echo "$onelf_sha256  $onelf.part" | sha256sum -c - > /dev/null
        chmod +x "$onelf.part"
        mv "$onelf.part" "$onelf"
    fi
fi

# pack <name>: pack the tree into a GL build and record its hash.
pack() {
    out=dist/$1-$arch.onelf
    "$onelf" sysroot pack-gl "$work/$1-tree" -o "$out" | tee "$work/$1.log"
    hash=$(grep -o '[0-9a-f]\{64\}' "$work/$1.log" | tail -n 1)
    if [ -z "$hash" ]; then
        echo "pack-gl printed no hash for $out" >&2
        exit 1
    fi
    echo "$hash" > "$out.blake3"
}

rm -rf dist
mkdir -p dist
tree gl 0
tree gl-vulkan 1
pack gl
pack gl-vulkan

ls -l dist
