<div align="center">

# 🔬 Kernel Inspector

**A macOS kext & Mach-O inspector that grew into an all-in-one Hackintosh / OpenCore toolkit.**

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-black?logo=apple)](https://luminadevapps.com)
[![Swift](https://img.shields.io/badge/Swift-F05138?logo=swift&logoColor=white)](https://developer.apple.com/swift/)
[![Website](https://img.shields.io/badge/website-luminadevapps.com-1575F9)](https://luminadevapps.com)

Made by [**Lumina Dev Apps**](https://luminadevapps.com) · Oshawa, Ontario, Canada

</div>

---

## Overview

**Kernel Inspector** started as a kernel-extension (`.kext`) and Mach-O inspector — modelled loosely on Hopper Disassembler — and has grown into an all-in-one **Hackintosh / OpenCore toolkit**. Open a `.kext` bundle or a raw binary to explore it, then use the system panes to generate SSDTs, derive OpenCore patches from *your own* machine, map USB ports, and install kexts.

Everything is organised into two groups in the sidebar.

## 🧭 Panes

### 🔎 Analyze

| Pane | What it does |
|------|--------------|
| **Info.plist** | Browse a kext's bundle metadata and dependencies |
| **Hex Editor** | Inspect raw binary bytes |
| **Symbols** | List exported/imported symbols in the Mach-O |
| **Disassembly** | Read disassembled machine code |
| **Control Flow** | Visualize branching and code paths |
| **Pseudocode** | Higher-level decompiled view |
| **Port-Limit Patch** | Derive the USB port-limit patch from the loaded binary |

### 🛠️ System

| Pane | What it does |
|------|--------------|
| **Install Kexts** | Install kernel extensions to your system |
| **Maintenance** | Common system maintenance actions |
| **USB Ports** | Map and label USB ports for a clean port config |
| **XCPM / CPU** | CPU power-management inspection and tuning |
| **SSDT Generator** | Generate OpenCore-ready ACPI SSDTs |

## 📦 Requirements

- **macOS 13.0+**
- A Mac (Apple Silicon or Intel) — many System panes target Intel / OpenCore builds

## 🚀 Building from source

1. Open the Xcode project in **Xcode 16**.
2. Select the app scheme, target **My Mac**, and set your signing **Team**.
3. Build & run (**⌘R**).

## 💬 Support

- 🌐 [luminadevapps.com](https://luminadevapps.com)
- ✉️ support@luminadevapps.com

> ⚠️ Kernel Inspector reads and can install low-level system extensions. Always verify patches and port maps against your own hardware before relying on them.

## License

© 2026 **Lumina Dev Apps** — a division of Direct Parcel Distributors Inc.
