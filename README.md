<h1 align="center">
  <img loading="lazy" src="readme-res/banner.png"/>
</h1>

<p align="center">LegacyUI is an Android 16 / One UI 8.0 port for the Samsung Galaxy A70</p>

# Base
LegacyUI brings a pure One UI 8.0 (Android 16) implementation based on Galaxy A36 (`SM-A366B`) firmware with UN1CA core patches to the Galaxy A70 (`a70q`).
Unlike its parent project and other forks, LegacyUI focuses on a reimplementation of the Galaxy A36 firmware on the Galaxy A70, providing a modern API level while keeping proprietary hardware functions working.

# Supported Devices
- **Samsung Galaxy A70 International:** `SM-A705FN` / `SM-A705F` (Tested & Verified)

> [!NOTE]
> Other regional variants (`SM-A705MN`, `SM-A705GM`, `SM-A7050`) are currently untested. Use at your own risk.
> Some revisions use NXP PN553 which is unsupported by One UI 7+. If NFC fails to launch, disable NFC after initial setup.

# Current Status
| Feature | Status | Notes |
|---|---|---|
| **Android 16 / One UI 8** | **Working** | Boots cleanly, daily driver stable |
| **Cellular (4G LTE / Data)** | **Working** | Mobile data & SIM detection working |
| **VoLTE** | **Working** | Both incoming and outgoing calls verified |
| **Wi-Fi** | **Working** | 2.4 GHz & 5 GHz connections verified |
| **Bluetooth Audio** | **Working** | Media playback verified with headphones |
| **Camera** | **Working (7/7)** | Rear/front capture, 1080p video, flash, autofocus |
| **Root** | **Working** | KernelSU Legacy built into Prime Kernel |
| **Face Recognition** | **In Progress** | Modern AIDL stack in testing |
| **Fingerprint** | **Untested** | Defective hardware sensor on current test unit |

# How to Build

### Prerequisites
Ensure standard Android build tools, Python, and bash are installed.

### Build Steps
```bash
# 1. Download and extract source firmwares
bash scripts/make_rom.sh -d -s a70q

# 2. Build flashable ROM zip
bash scripts/make_rom.sh -f a70q
```

Output flashable packages will be generated in `out/`.

# Licensing
UN1CA's build engine abides by the GNU GPLv3 license like the original project. The same applies to LegacyUI.

# Credits
LegacyUI:
- **[Tisenu100](https://github.com/tisenu100)** the Master Kanger
- **[rtd1250](https://github.com/rtd1250)** for the main Galaxy A70 support device trees
- **[Pascua](https://github.com/pascua28)** for his work upstreaming & improvising the SM6150 kernel via Prime
- **[ExtremeXT](https://github.com/ExtremeXT)** for the Bluetooth Patch Upstream & contributions on documenting the OneUI 7+ framework
- **[Peter Knecht](https://github.com/PeterKnecht93)** for assisting on cameradata bringup for legacy devices
- **Samsung SM6150 Team** for their support on keeping Samsung SM6150 devices alive

UN1CA Build engine by:
- **[Salvo](https://github.com/salvogiangri)** project founder and developer of the build system

# Honorable Mentions
- **[A70Q-Lineage](https://github.com/a70q-lineage/)** Sources for AOSP bringup on the Galaxy A70. Now merged with official LineageOS trees

# Kernel Sources
- **[Kernel Source](https://github.com/pascua28/android_kernel_samsung_sm7150)** – Prime Kernel by Pascua
