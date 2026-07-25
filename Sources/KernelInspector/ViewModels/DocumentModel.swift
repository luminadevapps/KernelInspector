import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class DocumentModel: ObservableObject {
    @Published var target: KextTarget?
    @Published var image: MachOImage?
    @Published var fileData: Data = Data()          // raw bytes of the binary (patchable)
    @Published var instructions: [Instruction] = []
    @Published var status: String = "Open a .kext bundle or a Mach-O binary to begin."
    @Published var isDisassembling = false
    @Published var backendName: String = Disassembler.availableBackend()?.rawValue ?? "none found"

    var isLoaded: Bool { image != nil }

    // MARK: Loading

    /// Clear the loaded binary and return to the welcome screen.
    func reset() {
        target = nil
        image = nil
        fileData = Data()
        instructions = []
        functionCache = []
        isDisassembling = false
        status = "Open a .kext bundle or a Mach-O binary to begin."
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true         // allow selecting a .kext bundle
        panel.allowsMultipleSelection = false
        panel.message = "Select a .kext bundle or a Mach-O binary"
        panel.treatsFilePackagesAsDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            load(url: url)
        }
    }

    func load(url: URL) {
        guard let t = KextTarget.open(url) else {
            status = "Could not open \(url.lastPathComponent)."
            return
        }
        guard let data = try? Data(contentsOf: t.binaryURL) else {
            status = "Could not read binary at \(t.binaryURL.lastPathComponent)."
            return
        }
        guard let img = MachOParser.parse(data) else {
            status = "\(t.binaryURL.lastPathComponent) is not a recognised Mach-O file."
            return
        }
        target = t
        fileData = data
        image = img
        instructions = []
        functionCache = []
        status = "Loaded \(t.displayName) — \(img.arch), \(img.fileType), \(img.symbols.count) symbols."
        disassemble()
    }

    // MARK: Disassembly

    func disassemble() {
        guard let t = target, let img = image else { return }
        isDisassembling = true
        let url = t.binaryURL
        let arch = img.arch
        let data = fileData
        Task.detached(priority: .userInitiated) {
            let raw = Disassembler.disassemble(binaryURL: url, arch: arch)
            let insns = Disassembler.fillBytes(raw, image: img, data: data, arch: arch)
            await MainActor.run {
                self.instructions = insns
                self.computeFunctions()          // O(n) slice, done once
                self.isDisassembling = false
                if insns.isEmpty {
                    self.status = "Disassembly returned nothing (backend: \(self.backendName)). Check that Xcode Command Line Tools are installed."
                } else {
                    self.status = "Disassembled \(insns.count) instructions with \(self.backendName)."
                }
            }
        }
    }

    // MARK: Symbols → functions

    /// Computed once after disassembly and cached — a large kext has tens of
    /// thousands of instructions, so this must be a single linear pass, not a
    /// per-function filter (which was O(functions × instructions) and hung the UI).
    private var functionCache: [(symbol: Symbol, insns: [Instruction])] = []

    func functions() -> [(symbol: Symbol, insns: [Instruction])] { functionCache }

    func computeFunctions() {
        guard let img = image, !instructions.isEmpty else { functionCache = []; return }
        let sorted = instructions.sorted { $0.address < $1.address }

        // Defined text symbols, unique & ascending by address.
        var seen = Set<UInt64>()
        let funcSyms = img.symbols
            .filter { $0.isDefined && !$0.isDebug && $0.value != 0 }
            .sorted { $0.value < $1.value }
            .filter { seen.insert($0.value).inserted }

        guard !funcSyms.isEmpty else {
            functionCache = [(Symbol(name: "__text", value: sorted.first?.address ?? 0,
                                     type: 0, sect: 1), sorted)]
            return
        }

        // Single forward walk: instructions are contiguous, ranges are
        // [sym.value, nextSym.value), so the cursor only moves forward.
        var result: [(Symbol, [Instruction])] = []
        var idx = 0
        let n = sorted.count
        for (i, sym) in funcSyms.enumerated() {
            let start = sym.value
            let end = (i + 1 < funcSyms.count) ? funcSyms[i + 1].value : UInt64.max
            while idx < n && sorted[idx].address < start { idx += 1 }
            var j = idx
            while j < n && sorted[j].address < end { j += 1 }
            if j > idx { result.append((sym, Array(sorted[idx..<j]))) }
            idx = j
        }
        functionCache = result
    }

    // MARK: Patching / saving

    func patch(offset: Int, bytes: [UInt8]) {
        guard offset >= 0, offset + bytes.count <= fileData.count else { return }
        for (i, b) in bytes.enumerated() {
            fileData[fileData.startIndex + offset + i] = b
        }
        status = "Patched \(bytes.count) byte(s) at 0x\(String(offset, radix: 16))."
        objectWillChange.send()
    }

    func saveAsPanel() {
        guard !fileData.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (target?.binaryURL.lastPathComponent ?? "binary") + ".patched"
        panel.message = "Save the patched binary"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try fileData.write(to: url)
                status = "Saved patched binary to \(url.lastPathComponent)."
            } catch {
                status = "Save failed: \(error.localizedDescription)"
            }
        }
    }
}
