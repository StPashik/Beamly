#!/usr/bin/env python3
"""Build standalone universal FFmpeg tools from verified source, never Homebrew libraries."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SOURCES = json.loads((ROOT / "Resources/Media-sources.json").read_text())
DOWNLOADS = ROOT / ".build/media-sources"
OUTPUT = ROOT / ".build/media-universal"
JOBS = str(min(8, os.cpu_count() or 2))


def run(arguments, cwd, env):
    print("Running:", " ".join(map(str, arguments)), flush=True)
    subprocess.run(list(map(str, arguments)), cwd=cwd, env=env, check=True)


def source_archive(name):
    source = SOURCES[name]
    path = DOWNLOADS / source["archive"]
    if not path.exists():
        pending = path.with_suffix(path.suffix + ".download")
        run(["curl", "--fail", "--location", "--retry", "2", "--max-time", "300",
             source["url"], "--output", pending], ROOT, os.environ)
        pending.replace(path)
    if hashlib.sha256(path.read_bytes()).hexdigest() != source["sha256"]:
        raise RuntimeError(f"Incorrect source SHA-256: {path}")
    return path


def extract(name, work):
    destination = work / SOURCES[name]["directory"]
    if not destination.exists():
        # Even verified archives must not extract outside the private build directory.
        with tarfile.open(source_archive(name)) as archive:
            archive.extractall(work, filter="data")
    return destination


def make_install(source, build, options, env):
    build.mkdir(exist_ok=True)
    run([source / "configure", *options], build, env)
    run(["make", f"-j{JOBS}"], build, env)
    run(["make", "install"], build, env)


def build(work):
    host_prefix = work / "host"
    host_prefix.mkdir(exist_ok=True)
    env = dict(os.environ, PATH=f"{host_prefix / 'bin'}:{os.environ['PATH']}",
               PKG_CONFIG_PATH="", PKG_CONFIG_LIBDIR="/nonexistent", PYTHONNOUSERSITE="1",
               PIP_CACHE_DIR=str(ROOT / ".build/media-pip-cache"), PIP_DISABLE_PIP_VERSION_CHECK="1")
    # Build tools stay private: no brew install, global pip install, or codec-library discovery.
    for name in ["m4", "autoconf", "automake", "libtool", "nasm"]:
        executable = host_prefix / "bin" / name
        if executable.exists() and SOURCES[name]["version"] in subprocess.check_output([executable, "--version"], text=True).splitlines()[0]:
            continue
        make_install(extract(name, work), work / f"host-{name}",
                     [f"--prefix={host_prefix}"], env)
    venv = work / "python"
    run(["python3", "-m", "venv", venv], work, env)
    run([venv / "bin/python", "-m", "pip", "install", "meson==1.9.1", "ninja==1.13.0"], work, env)
    env["PATH"] = f"{venv / 'bin'}:{env['PATH']}"
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    licenses = OUTPUT / "Licenses"
    licenses.mkdir(parents=True, exist_ok=True)
    order = ["freetype", "fribidi", "harfbuzz", "libunibreak", "libass", "zimg", "dav1d", "x264", "ffmpeg"]
    for arch in ["arm64", "x86_64"]:
        prefix = work / f"install-{arch}"
        prefix.mkdir(exist_ok=True)
        flags = ["-arch", arch, "-mmacosx-version-min=14.0", "-isysroot", sdk, "-O2"]
        target_env = dict(env, CC="clang", CXX="clang++", CFLAGS=" ".join(flags),
                          CXXFLAGS=" ".join(flags), LDFLAGS=" ".join(flags),
                          MACOSX_DEPLOYMENT_TARGET="14.0", PKG_CONFIG_LIBDIR=str(prefix / "lib/pkgconfig"))
        host = "aarch64" if arch == "arm64" else arch
        cross = work / f"meson-{arch}.ini"
        cross.write_text("[binaries]\nc = 'clang'\ncpp = 'clang++'\nar = 'ar'\nstrip = 'strip'\n"
                         "pkg-config = 'pkg-config'\n[host_machine]\nsystem = 'darwin'\n"
                         f"cpu_family = {'aarch64' if arch == 'arm64' else 'x86_64'!r}\n"
                         f"cpu = {host!r}\nendian = 'little'\n[built-in options]\n"
                         f"c_args = {flags!r}\ncpp_args = {flags!r}\nc_link_args = {flags!r}\ncpp_link_args = {flags!r}\n")
        configurations = OUTPUT / "Configurations" / arch
        configurations.mkdir(parents=True, exist_ok=True)
        for name in order:
            source = extract(name, work)
            directory = work / f"{name}-{arch}"
            if name == "fribidi":
                directory = work / f"{name}-{arch}-meson"
            static = [f"--prefix={prefix}", f"--host={host}-apple-darwin", "--disable-shared", "--enable-static"]
            if name in ["freetype", "harfbuzz"]:
                options = [f"-DCMAKE_INSTALL_PREFIX={prefix}", f"-DCMAKE_OSX_ARCHITECTURES={arch}",
                           "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0", f"-DCMAKE_OSX_SYSROOT={sdk}",
                           "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_SHARED_LIBS=OFF"]
                if name == "freetype":
                    options += [f"-DFT_DISABLE_{lib}=ON" for lib in ["ZLIB", "BZIP2", "PNG", "HARFBUZZ", "BROTLI", "HVF"]]
                else:
                    options += [f"-DHB_BUILD_{part}=OFF" for part in ["UTILS", "SUBSET", "RASTER", "VECTOR", "GPU"]]
                    options += ["-DHB_HAVE_FREETYPE=OFF", "-DHB_HAVE_CORETEXT=ON"]
                run(["cmake", "-S", source, "-B", directory, *options], work, target_env)
                run(["cmake", "--build", directory, "--parallel", JOBS], work, target_env)
                run(["cmake", "--install", directory], work, target_env)
            elif name in ["fribidi", "dav1d"]:
                options = (["-Denable_tools=false", "-Denable_tests=false", "-Denable_examples=false"]
                           if name == "dav1d" else ["-Ddocs=false", "-Dbin=false", "-Dtests=false"])
                run(["meson", "setup", directory, source, "--cross-file", cross, f"--prefix={prefix}",
                     "--libdir=lib", "--default-library=static", "--buildtype=release", "--wrap-mode=nodownload",
                     *options], work, target_env)
                run(["meson", "compile", "-C", directory, "-j", JOBS], work, target_env)
                run(["meson", "install", "-C", directory], work, target_env)
            else:
                if name == "zimg" and not (source / "configure").exists():
                    run(["autoreconf", "-fi"], source, target_env)
                if name == "libass":
                    options = static + ["--disable-fontconfig", "--enable-coretext", "--enable-libunibreak"]
                elif name == "x264":
                    options = [f"--prefix={prefix}", f"--host={host}-apple-darwin", "--enable-static",
                               "--enable-pic", "--disable-cli", "--disable-opencl"]
                elif name == "ffmpeg":
                    options = [f"--prefix={prefix}", "--cc=clang", f"--arch={arch}", "--target-os=darwin",
                               "--enable-cross-compile", f"--sysroot={sdk}", "--enable-static", "--disable-shared",
                               "--disable-autodetect", "--enable-pic", "--enable-gpl", "--disable-version3",
                               "--disable-nonfree", "--disable-doc", "--disable-debug", "--disable-ffplay",
                               "--disable-indevs", "--disable-outdevs", "--enable-indev=lavfi", "--disable-network",
                               "--disable-protocols", "--enable-protocol=file,pipe,fd,data,crypto",
                               "--enable-libass", "--enable-libzimg",
                               "--enable-libdav1d", "--enable-libx264", "--enable-videotoolbox", "--enable-audiotoolbox", "--enable-zlib",
                               "--pkg-config-flags=--static", f"--extra-cflags={' '.join(flags)} -I{prefix / 'include'}",
                               f"--extra-ldflags={' '.join(flags)} -L{prefix / 'lib'}", "--extra-libs=-lc++"]
                else:
                    options = static
                make_install(source, directory, options, target_env)
            for relative in ["config.h", "ffbuild/config.mak", "config_components.h"]:
                path = directory / relative
                if path.exists():
                    shutil.copy2(path, configurations / f"{name}-{Path(relative).name}")
            license_dir = licenses / name
            license_dir.mkdir(exist_ok=True)
            for pattern in ["COPYING*", "LICENSE*", "LICENCE*", "docs/FTL.TXT", "docs/GPLv2.TXT"]:
                for path in source.glob(pattern):
                    if path.is_file():
                        shutil.copy2(path, license_dir / path.name)
        tools = OUTPUT / arch
        tools.mkdir(exist_ok=True)
        for name in ["ffmpeg", "ffprobe"]:
            shutil.copy2(prefix / "bin" / name, tools / name)
            run(["lipo", tools / name, "-verify_arch", arch], work, env)
    helpers = OUTPUT / "Helpers"
    helpers.mkdir(exist_ok=True)
    for name in ["ffmpeg", "ffprobe"]:
        path = helpers / name
        run(["lipo", "-create", OUTPUT / "arm64" / name, OUTPUT / "x86_64" / name, "-output", path], work, env)
        libraries = subprocess.check_output(["otool", "-L", path], text=True)
        for line in libraries.splitlines():
            if "compatibility version" in line and not line.strip().startswith(("/usr/lib/", "/System/Library/")):
                raise RuntimeError(f"Non-system runtime dependency: {line}")
        run(["codesign", "--force", "--sign", "-", path], work, env)
    shutil.copy2(ROOT / "Resources/Media-sources.json", licenses / "Media-sources.json")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rebuild", action="store_true")
    args = parser.parse_args()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    DOWNLOADS.mkdir(parents=True, exist_ok=True)
    fingerprint = hashlib.sha256(Path(__file__).read_bytes() + (ROOT / "Resources/Media-sources.json").read_bytes()).hexdigest()
    stamp = OUTPUT / "build.sha256"
    if not args.rebuild and stamp.exists() and stamp.read_text().strip() == fingerprint:
        for name in ["ffmpeg", "ffprobe"]:
            subprocess.run(["lipo", str(OUTPUT / "Helpers" / name), "-verify_arch", "arm64", "x86_64"], check=True)
        print("Bundled media tools are up to date.")
        return
    stamp.unlink(missing_ok=True)
    for name in SOURCES:
        source_archive(name)
    # Keep failed compiler work for diagnosis/retry; never use paths containing spaces in upstream makefiles.
    receipt = ROOT / ".build/media-work.txt"
    work = Path(receipt.read_text().strip()) if receipt.exists() else Path(tempfile.mkdtemp(prefix="beamly-media-", dir="/private/tmp"))
    if work.parent != Path("/private/tmp") or not work.name.startswith("beamly-media-"):
        raise RuntimeError("Unexpected media work directory")
    work.mkdir(exist_ok=True)
    receipt.write_text(str(work) + "\n")
    build(work)
    stamp.write_text(fingerprint + "\n")
    shutil.rmtree(work)
    receipt.unlink()
    print(f"Built universal tools: {OUTPUT / 'Helpers'}")


if __name__ == "__main__":
    main()
