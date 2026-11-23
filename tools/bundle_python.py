"""Stage pinned, relocatable CPython distributions at application build time."""
import hashlib
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CACHE = Path(os.getenv("PYVIS_DOWNLOAD_CACHE", Path.home() / "Library/Caches/Pyvis/cpython"
                       if sys.platform == "darwin" else Path.home() / ".cache/pyvis/cpython"))
VERSION = "3.14.7"
MAC = {"arm64": ("aarch64", "423717c485b9ee7822590b9d973c1b5fb2cda0fe43448ab82a3d44f823bd329c"),
       "x86_64": ("x86_64", "e085b44e21d9c60acd866680747e1f82800cf9a1630a369da1723976d87bead1")}
ANDROID = {"arm64-v8a": ("aarch64", "6d50cc3aa66e414a439594089bcdfb5f1264358155c70c1f00471c24cfb477fb"),
           "x86_64": ("x86_64", "2c16ce2359565cd8c24f86cfb75630768ba6607e732946b294b969797f583b60")}


def archive(url, digest):
    CACHE.mkdir(parents=True, exist_ok=True)
    dest = CACHE / url.rsplit("/", 1)[1]
    if not dest.exists() or hashlib.sha256(dest.read_bytes()).hexdigest() != digest:
        with tempfile.TemporaryDirectory(dir=CACHE) as stage:
            download = Path(stage) / "download"
            subprocess.run(["curl", "-fLsS", "--retry", "3", url, "-o", download], check=True)
            if hashlib.sha256(download.read_bytes()).hexdigest() != digest:
                raise ValueError("Python distribution checksum mismatch: " + url)
            download.replace(dest)
    return dest


def macos():
    contents = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["CONTENTS_FOLDER_PATH"]
    identity = os.getenv("EXPANDED_CODE_SIGN_IDENTITY") or "-"
    for arch in os.environ["ARCHS"].split():
        target, digest = MAC[arch]
        name = f"cpython-{VERSION}+20260814-{target}-apple-darwin-install_only_stripped.tar.gz"
        package = archive("https://github.com/astral-sh/python-build-standalone/releases/download/20260814/" + name, digest)
        dest = contents / "Resources" / "cpython" / arch
        dest.mkdir(parents=True, exist_ok=True)
        subprocess.run(["tar", "-xf", package, "-C", dest], check=True)
        for file in (dest / "python").rglob("*"):
            if file.is_symlink() or not file.is_file():
                continue
            with file.open("rb") as stream:
                if stream.read(4) != b"\xcf\xfa\xed\xfe":
                    continue
            entitlements = ["--entitlements", ROOT / "client/macos/Runner/EditorTool.entitlements"] if file.parent.name == "bin" else []
            subprocess.run(["codesign", "-f", "-s", identity, "--options", "runtime",
                            "--timestamp=none", *entitlements, file], check=True)


def android(output, ndk):
    assets = output / "assets" / "cpython"
    if assets.is_dir():
        shutil.rmtree(assets)
    assets.mkdir(parents=True, exist_ok=True)
    host = {"Darwin": "darwin", "Linux": "linux", "Windows": "windows"}[platform.system()]
    clang = ndk / "toolchains/llvm/prebuilt" / (host + "-x86_64") / "bin" / ("clang.exe" if host == "windows" else "clang")
    with zipfile.ZipFile(assets / "runtime.zip", "w", zipfile.ZIP_DEFLATED) as runtime:
        for file in sorted((ROOT / "runtime/pyvis_runtime").rglob("*")):
            if file.is_file() and not any(i in ("__pycache__", "tools") or i.startswith(".") for i in file.parts):
                runtime.write(file, file.relative_to(ROOT / "runtime"))
    for abi, (arch, digest) in ANDROID.items():
        url = f"https://www.python.org/ftp/python/{VERSION}/python-{VERSION}-{arch}-linux-android.tar.gz"
        package = archive(url, digest)
        native = output / "jniLibs" / abi
        native.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory() as stage:
            subprocess.run(["tar", "-xf", package, "-C", stage], check=True)
            lib = Path(stage) / "prefix/lib"
            stdlib = lib / "python3.14"
            for name in ["libpython3.14.so", "libcrypto_python.so", "libssl_python.so", "libsqlite3_python.so"]:
                shutil.copy2(lib / name, native / name)
            for module in (stdlib / "lib-dynload").glob("*.so"):
                shutil.copy2(module, native / ("libpyext_" + module.name.split(".")[0] + ".so"))
            # Android loads ABI-specific extension modules from the APK's native directory.
            # Both builds share the pure-Python library. Use an outer-compressible asset
            # while keeping the extracted zip readable before zlib is imported.
            if abi == "arm64-v8a":
                with zipfile.ZipFile(assets / "stdlib.payload", "w") as z:
                    for file in sorted(stdlib.rglob("*")):
                        path = file.relative_to(stdlib)
                        excluded = {"lib-dynload", "__pycache__", "test", "tests", "ensurepip", "site-packages"}
                        if (file.is_file() and not set(path.parts).intersection(excluded)
                                and not path.parts[0].startswith(("config-", "_sysconfig"))
                                and path.name != "build-details.json"):
                            z.write(file, path)
            with zipfile.ZipFile(assets / (abi + ".zip"), "w", zipfile.ZIP_DEFLATED) as z:
                for file in [*stdlib.glob("_sysconfig*"), stdlib / "build-details.json"]:
                    z.write(file, file.name)
            subprocess.run([clang, "--target=" + arch + "-linux-android24", "-fPIE", "-pie",
                            "-Wl,-z,max-page-size=16384", "-o", native / "libpyvis_cli.so",
                            ROOT / "tools/android_python.c", "-L" + str(native), "-lpython3.14"], check=True)


if __name__ == "__main__":
    if sys.argv[1] == "macos":
        macos()
    elif sys.argv[1] == "android":
        android(Path(sys.argv[2]), Path(sys.argv[3]))
