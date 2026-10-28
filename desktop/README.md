# Cross-platform desktop app

This Flutter application uses the shared Rust library in `../core` for device
discovery, serial communication, remote scanning, pairing, power and 16-step
brightness/temperature targets. The original Swift macOS application remains
available as a reference in `../mac`.

The desktop app is experimental. The firmware sends commands over a one-way
radio link: the lamp does not report whether a command was received, and the
sliders display requested targets rather than measured state. Pairing a new ID
may replace the original remote's binding.

## Building

Use Flutter 3.47.8, a current Rust toolchain, and the native build tools for the
target platform. Build on the target OS (macOS can build both Mac architectures).
The repository scripts compile the core, run checks, assemble the Flutter app,
bundle the native library and collect licenses into `../build/artifacts/`:

```sh
# macOS: install Rust targets aarch64-apple-darwin and x86_64-apple-darwin
bash scripts/build-macos.sh

# Linux x86_64: install GTK 3, libudev, Clang, CMake, Ninja and X11 headers
bash scripts/build-linux.sh
```

On Windows x86_64, use a Visual Studio desktop C++ toolchain and PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-windows.ps1
```

These commands are run from the repository root. The scripts produce test
archives; macOS is ad-hoc signed and Windows is unsigned. Distribution signing
and notarization are not configured. A manual GitHub Actions workflow is also
provided in `.github/workflows/desktop-builds.yml`.

Windows builds also produce `Xiaomi-Lightbar-Windows-x86_64.exe`, a single
portable executable. Its first launch extracts a versioned runtime into the
current user's local application-data folder, which can be deleted to remove
the cached files. The bundle includes the required Visual C++ runtime DLLs.

The Linux builder can also run in Docker on another host:

```sh
docker build --platform linux/amd64 -f scripts/linux-builder.Dockerfile -t lightbar-linux-builder:3.47.8 .
docker run --rm --platform linux/amd64 -v "$PWD:/workspace" lightbar-linux-builder:3.47.8 bash scripts/build-linux.sh
```

The serial simulator uses Unix pseudo-terminals and is run as part of the Linux
build. On macOS the serial library cannot set a hardware baud rate on a PTY;
Rust unit tests run there instead. None of these tests replace testing with a
physical RF-Nano and lamp.

Flutter's current Intel macOS support is being phased out. Keep the pinned
version while validating this experimental build and revisit the platform
strategy before upgrading Flutter.
