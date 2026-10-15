#!/bin/bash
# Linux and Windows: ffmpeg and ffprobe for DigUp's packages, built small: LGPL, static, decoding only what people keep
# (common audio and video, and HEIC, WebP, TIFF and AVIF pictures), writing only what the engine asks for (16 kHz PCM,
# JPEG frames, PPM pictures). AV1 and AVIF decode with dav1d, built here too, and zlib is linked in: those three are
# all the licenses it carries (their texts land in Vendor/ffmpeg/licenses for the packages' notices). → Vendor/ffmpeg/bin
# (out of git). Does nothing when the pinned versions are already built. Needs a C compiler, make, meson and ninja,
# pkg-config, zlib's headers, and nasm on x86_64; on Windows, MSYS2's MINGW64 shell with its gcc, meson, ninja, nasm,
# pkgconf and zlib (the executables then need no DLLs).
set -euo pipefail
cd "$(dirname "$0")/.."
FFMPEG_VERSION=9.0.2
FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
DAV1D_VERSION=1.5.2
DAV1D_SHA256=cce88ebcffd3f790bde49caa75f97b9cc2dd54ca8f57e38c62707266ec71bc4e
OUT=$PWD/Vendor/ffmpeg
# The versions and this script (its lists of formats): either changing builds again.
STAMP="ffmpeg $FFMPEG_VERSION dav1d $DAV1D_VERSION $(sha256sum "$0" | cut -c1-12)"
if [[ "$(cat "$OUT/BUILD" 2>/dev/null)" == "$STAMP" ]]; then exit 0; fi

T=$PWD/Vendor/ffmpeg-tmp
rm -rf "$T" "$OUT"
mkdir -p "$T"
fetch() {   # url, sha256
  curl -sSLf -o "$T/${1##*/}" "$1"
  echo "$2  $T/${1##*/}" | sha256sum -c --quiet -
  tar -xJf "$T/${1##*/}" -C "$T"
}
fetch "https://downloads.videolan.org/pub/videolan/dav1d/$DAV1D_VERSION/dav1d-$DAV1D_VERSION.tar.xz" "$DAV1D_SHA256"
fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "$FFMPEG_SHA256"

echo "dav1d $DAV1D_VERSION"
(cd "$T/dav1d-$DAV1D_VERSION" &&
  meson setup build --prefix="$T/deps" --libdir=lib --default-library=static --buildtype=release \
    -Denable_tools=false -Denable_tests=false > /dev/null &&
  ninja -C build install > /dev/null)

list() { local IFS=,; echo "$*"; }
demuxers=(mov matroska avi mpegts mpegps flv ogg wav w64 aiff caf mp3 aac flac ac3 eac3 asf amr au wv ape tta dv
  image2 image2pipe webp_pipe tiff_pipe png_pipe jpeg_pipe bmp_pipe)
decoders=(h264 hevc mpeg4 msmpeg4v1 msmpeg4v2 msmpeg4v3 mpeg1video mpeg2video mjpeg vp8 vp9 libdav1d theora wmv1 wmv2
  wmv3 vc1 h263 flv prores dvvideo rawvideo png bmp webp tiff
  aac aac_latm mp3 mp3float mp2 mp2float mp1 flac vorbis opus alac ac3 eac3 wmav1 wmav2 wmapro amrnb amrwb wavpack ape
  tta gsm gsm_ms adpcm_ima_qt adpcm_ima_wav adpcm_ms pcm_s16le pcm_s16be pcm_s24le pcm_s24be pcm_s32le pcm_s32be
  pcm_f32le pcm_f32be pcm_f64le pcm_u8 pcm_alaw pcm_mulaw pcm_s16le_planar pcm_dvd pcm_bluray)
parsers=(h264 hevc mpeg4video mpegvideo vp8 vp9 av1 aac aac_latm mpegaudio flac opus vorbis ac3 mjpeg png webp bmp)
# What the ffmpeg command puts in by itself (format and size changes, rotation, HEIC's tile grids), and what DigUp asks.
filters=(buffer buffersink abuffer abuffersink null anull format aformat aresample scale fps crop pad overlay xstack
  hstack vstack transpose hflip vflip rotate setsar setdar copy trim atrim)

# Windows (MinGW): the C runtime linked in, so ffmpeg.exe and ffprobe.exe run without MinGW's DLLs.
static=()
case "$(uname -s)" in MINGW*|MSYS*) static=(--extra-ldflags=-static) ;; esac

echo "ffmpeg $FFMPEG_VERSION"
(cd "$T/ffmpeg-$FFMPEG_VERSION" &&
  PKG_CONFIG_PATH="$T/deps/lib/pkgconfig" ./configure --prefix="$OUT" --pkg-config-flags=--static "${static[@]}" \
    --disable-everything --disable-autodetect --disable-network --disable-doc --disable-debug --disable-ffplay \
    --enable-static --disable-shared --enable-zlib --enable-libdav1d \
    --enable-protocol=file,pipe \
    --enable-demuxer="$(list "${demuxers[@]}")" --enable-decoder="$(list "${decoders[@]}")" \
    --enable-parser="$(list "${parsers[@]}")" --enable-filter="$(list "${filters[@]}")" \
    --enable-encoder=pcm_s16le,mjpeg,ppm,rawvideo --enable-muxer=pcm_s16le,image2,image2pipe,rawvideo,null \
    > "$T/configure.log" 2>&1 &&
  # configure only warns about a name that matches no component: a typo would leave a format out.
  ! grep "did not match anything" "$T/configure.log" &&
  make -j"$(nproc)" > "$T/make.log" 2>&1 &&
  make install > /dev/null)
mkdir -p "$OUT/licenses"
cp "$T/ffmpeg-$FFMPEG_VERSION/COPYING.LGPLv2.1" "$OUT/licenses/ffmpeg-COPYING.LGPLv2.1"
cp "$T/ffmpeg-$FFMPEG_VERSION/LICENSE.md" "$OUT/licenses/ffmpeg-LICENSE.md"
cp "$T/dav1d-$DAV1D_VERSION/COPYING" "$OUT/licenses/dav1d-COPYING"
"$OUT/bin/ffmpeg" -hide_banner -version > "$OUT/licenses/ffmpeg-version.txt"
rm -rf "$OUT/include" "$OUT/lib" "$OUT/share" "$T"
echo "$STAMP" > "$OUT/BUILD"
ls -la "$OUT/bin"
