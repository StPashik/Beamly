# Bundled media tools

Beamly 1.0.4 includes standalone, universal FFmpeg and FFprobe executables in `Beamly.app/Contents/Helpers`. They run on macOS 14 or later on Apple Silicon and Intel. No Homebrew installation, codec download, Python, or Node runtime is required by the installed application. Releases through 1.0.3 still need a separate FFmpeg installation.

The existing playback paths are unchanged: compatible files play directly, supported HEVC/H.264 is remuxed without video encoding, and explicit compatibility conversion uses H.264/AAC. The bundled build includes libass with system CoreText fonts for subtitle burn-in, zimg for HDR-to-SDR conversion, dav1d for AV1 input decoding, and VideoToolbox hardware encoding. It includes the software H.264 encoder used when hardware encoding is disabled or fails. HEVC encoding is not needed for remuxing; libx265 is used only by the development test-fixture generator.

An explicitly selected tools folder takes priority, followed by bundled helpers. The old resource-folder locations and Homebrew paths remain fallback locations for source/development builds. Packaged builds normally use their own helpers. Original videos, existing queue data, and preferences are unchanged.

## Sources and licenses

FFmpeg/FFprobe and their statically linked libraries are independent command-line programs. Beamly invokes them as child processes and does not link FFmpeg libraries into its MIT-licensed application. The helpers have only macOS system runtime dependencies; the build rejects Homebrew or other external dynamic libraries.

The combined FFmpeg executables are distributed under **GPL version 2** because their existing software H.264 path uses libx264; FreeType's GPLv2 option is selected for this combination. `--enable-nonfree` and version-3-only components are disabled. FFmpeg's [license documentation](https://github.com/FFmpeg/FFmpeg/blob/master/LICENSE.md) explains GPL-enabled configurations. Beamly's own code, installer, and build recipes remain MIT licensed.

| Component | License |
| --- | --- |
| FFmpeg / FFprobe, x264 | GPL 2 or later |
| libass | ISC |
| FreeType | GPLv2 selected; source is also available under the alternative FTL |
| HarfBuzz | MIT-style notices |
| FriBidi | LGPL 2.1 or later |
| libunibreak | zlib/libpng-style license |
| zimg | WTFPL |
| dav1d | BSD 2-Clause |

Exact versions, upstream URLs, and SHA-256 checksums are in [Media-sources.json](../Resources/Media-sources.json). Original notices are copied into `Contents/Resources/Media-Licenses` during the build. Portions of this software are copyright © the FreeType Project; all rights reserved. This software is based in part on the work of the Independent JPEG Group. No upstream source patches are applied; zimg's configure files are generated with the pinned build tools.

Every release containing these helpers must publish **Beamly-FFmpeg-Sources-VERSION.tar.xz** beside its application ZIP in the [same GitHub Release](https://github.com/StPashik/Beamly/releases). `Scripts/release.sh` generates this source archive and includes its checksum. It contains all pinned upstream source archives, the exact build script and manifest, license notices, and both architecture configurations. Do not publish the bundled application without its corresponding source archive.

Users may rebuild and replace the helpers. This does not require Beamly's private update-signing key. Sign the modified application again with an ad-hoc development signature (`codesign --force --deep --sign - Beamly.app`) before local use; a modified application is not an official update. No additional restriction is imposed on debugging modifications to LGPL components.

## Build and validation

Build prerequisites: Xcode command-line tools, Python 3.12 or later, CMake, pkg-config, and make. The script builds the required Autotools and NASM in a private temporary directory and installs pinned Meson/Ninja only into a private virtual environment. It does not install or upgrade global Homebrew/pip packages. Downloads use HTTPS and pinned source checksums. An internet connection is needed for the first source and build-tool downloads.

```sh
python3 Scripts/build-media.py
Scripts/build.sh
BEAMLY_TEST_APP_BUNDLE="$PWD/build/Beamly.app" Scripts/test.sh
```

The media build produces arm64 and x86_64 tools, combines them with lipo, checks system-only linkage, and signs them. Apple Silicon validation runs both CPU slices using Rosetta 2 for Intel; install Rosetta before running the full release checks on that host. Intel hosts inspect both slices but execute only x86_64. Both the command-line app builder and Xcode's embed phase copy and sign the same helpers. Run the media build before opening the Xcode project, and rerun it after changing its recipe or source manifest. Private compiler work is retained after a failure for diagnosis/retry and removed on success. `--rebuild` executes the build recipe again; a matching completed recipe is reused.

Tests generate small private fixtures, use the bundled tools for the playback pipeline, and retain 4K frame, HDR metadata, seek, audio, and subtitle checks. Install `ffmpeg-full` on the developer/CI machine for the libx265 fixture generator; it is not a runtime dependency of Beamly.

**Physical 4K/HDR AirPlay testing has not been performed.** These builds and local tests do not certify receiver compatibility or actual HDR display activation.
