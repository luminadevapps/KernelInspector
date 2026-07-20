# Kernel Inspector

An all-in-one macOS app for inspecting **kernel extensions (`.kext`)** and Mach-O
binaries — modelled loosely on Hopper Disassembler. Open a bundle or a raw binary
and explore it through six panes:

| Pane | What it does |
|------|--------------|
| **Info.plist** | Kext bundle browser: identifier, version, UUID, linked libraries, and a flattened, searchable Info.plist table. |
| **Hex Editor** | Byte-level view with **hex find & replace**, match navigation, in-memory patching, and *Save Patched Binary…*. |
| **Symbols** | Full symbol table (nlist_64) with kind filtering (global / local / undefined / debug) and text search. |
| **Disassembly** | ARM64 / x86-64 disassembly of the `__text` section, colour-coded by branch / call / return. |
| **Control Flow** | Basic-block control-flow graph built per function, with successor edges. |
| **Pseudocode** | Experimental heuristic pseudo-C (`if (cond) goto loc_x;`) — a readability aid, not a real decompiler. |
| **Install Kexts** | Hackintosh-style installer: system-readiness dashboard (SIP, macOS/build, target dir, cache tool), pick a `.kext`, copy to `/Library/Extensions` with root:wheel ownership, rebuild caches, and uninstall. Privileged steps use the macOS admin prompt — the app never sees your password. |
| **Maintenance** | System-maintenance tools: mount/unmount the **EFI partition**, manage **Kernel Debug Kits** (list, uninstall, open Apple's download page), and clean up **APFS snapshots**. Mutating actions use the macOS admin prompt. |

## Requirements

- macOS 13 (Ventura) or later
- Xcode 15+ (or the Swift 5.9 toolchain)
- **Xcode Command Line Tools** — the disassembler shells out to `otool`
  (preferred) or `llvm-objdump`, both of which ship with the tools:
  ```
  xcode-select --install
  ```

## Build a double-clickable app (recommended)

This produces a real `Kernel Inspector.app` with the bundle ID
`com.lumina.KernelInspector`, an app icon, and no launch-time console warnings:

```bash
cd KernelInspector
./build_app.sh
```

The script builds a release binary, wraps it in an `.app` bundle, generates the
`.icns` icon, ad-hoc code-signs it, and opens it. The finished app lands in
`build/Kernel Inspector.app` — drag it to `/Applications` if you like.

### Why the terminal build showed warnings

Running `swift run` launches a bare executable with **no bundle identifier**, so
macOS logs harmless `com.apple.linkd.autoShortcut` / "missing main bundle
identifier" messages. The `.app` bundle above has a proper identifier, so those
messages disappear.

## Open as an Xcode project

The repo ships an [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec that
generates a proper `.xcodeproj` App target:

```bash
brew install xcodegen
xcodegen generate
open KernelInspector.xcodeproj      # then press ⌘R
```

## Quick run (no bundle)

The project is also a plain Swift Package:

```bash
cd KernelInspector
swift run          # build & launch (expect the harmless warnings noted above)
open Package.swift # or open the package directly in Xcode
```

## Usage

1. Press **⌘O** (or *Open*) and choose a `.kext` bundle *or* a Mach-O file.
   Kexts are resolved to their `Contents/MacOS/<executable>` automatically.
2. The app parses the Mach-O header, load commands, segments/sections and the
   symbol table itself (no external parser), then disassembles the text section.
3. In **Hex Editor**, type a pattern like `55 48 89 E5`, press **Find**, then
   **Replace** / **Replace All** (replacement must be the same byte length).
   Use **Save Patched** (⌘S) to write the modified bytes to a new file.

> Kexts on disk are often SIP-protected and code-signed. Patching a copy is fine
> for study; loading a modified kext requires disabling signature enforcement and
> is outside this tool's scope.

## Architecture

```
Sources/KernelInspector/
├── KernelInspectorApp.swift     @main entry + menu commands
├── ContentView.swift            NavigationSplitView shell + status bar
├── Models/
│   ├── ByteReader.swift         endian-aware byte reader
│   ├── MachO.swift              FAT + thin Mach-O parser (header, LCs, sections)
│   ├── Symbol.swift             LC_SYMTAB / nlist_64 parsing
│   ├── KextBundle.swift         .kext resolution + Info.plist
│   ├── Instruction.swift        instruction model + flow heuristics
│   ├── Disassembler.swift       otool / llvm-objdump backend wrapper
│   ├── CFG.swift                basic-block / control-flow builder
│   └── Pseudocode.swift         heuristic pseudo-C renderer
├── ViewModels/DocumentModel.swift   load, disassemble, patch, save
└── Views/                       one SwiftUI view per pane
```

## Swapping in Capstone (optional)

The disassembly backend is isolated in `Disassembler.swift`. To use the
[Capstone](https://www.capstone-engine.org) engine directly instead of shelling
out:

1. `brew install capstone`
2. Add a SwiftPM system-library target wrapping `<capstone/capstone.h>`.
3. Implement a `case capstone` in `Disassembler.Backend` that feeds the raw
   `__text` bytes (already available via `MachSection.offset/size` on
   `doc.fileData`) into `cs_disasm` and maps results into `Instruction`.

The rest of the app (CFG, pseudocode, views) consumes the `[Instruction]` array
unchanged.

## Notes & limitations

- Pseudocode and CFG are heuristic and best-effort; they do not do full data-flow
  or type recovery.
- The parser targets 64-bit Mach-O (the norm for modern kexts); 32-bit magic is
  recognised but less exercised.
- This is a study / reverse-engineering aid for binaries you own or are permitted
  to analyse.
