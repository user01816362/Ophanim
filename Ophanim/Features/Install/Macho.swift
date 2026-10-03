//
//  Macho.swift
//  Ophanim
//
//  Mach-O conversion for Catalyst: strip fat binaries to the arm64 slice, rewrite
//  the version command, redirect @rpath Swift libs; plus encryption/arch queries
//  and a loadability inspector sharing the engine's own command iterator.
//

import Foundation

/// Mach-O rewriter: fat→arm64 strip, Catalyst version command, @rpath Swift-lib
/// redirect. Operates on Data in memory; the caller replaces the file on success.
class Macho {
    /// Keeps only the arm64 slice of a fat binary (in place).
    ///
    /// - Parameter binary: The Mach-O bytes; replaced with the arm64 slice.
    /// - Throws: `OphanimError.failedToStripBinary` when no arm64 slice exists.
    static func stripBinary(_ binary: inout Data) throws {
        var header = binary.extract(fat_header.self)
        var offset = MemoryLayout.size(ofValue: header)
        let shouldSwap = header.magic == FAT_CIGAM

        if header.magic == FAT_MAGIC || header.magic == FAT_CIGAM {
            // Make sure the endianness is correct
            if shouldSwap {
                swapFatHeader(&header, NXHostByteOrder())
            }

            for _ in 0..<header.nfat_arch {
                var arch = binary.extract(fat_arch.self, offset: offset)
                if shouldSwap {
                    swapFatArch(&arch, NXHostByteOrder())
                }

                if arch.cputype == CPU_TYPE_ARM64 {
                    print("Found ARM64 arch in fat binary")

                    binary = binary
                        .subdata(in: Int(arch.offset)..<Int(arch.offset+arch.size))

                    return
                }

                offset += Int(MemoryLayout.size(ofValue: arch))
            }

            throw OphanimError.failedToStripBinary
        }
    }

    /// Full conversion for one Mach-O on disk: strip, version command, library paths.
    ///
    /// - Parameter macho: The file to convert (replaced atomically via remove+write).
    /// - Throws: Strip/rewrite errors or file I/O failures.
    static func convertMacho(_ macho: URL) throws {
        print("Converting MachO at \(macho.path)")

        var binary = try Data(contentsOf: macho)

        print("Stripping MachO...")
        try stripBinary(&binary)
        print("Replacing version command...")
        try replaceVersionCommand(&binary)
        print("Replacing instances of @rpath dylibs...")
        try replaceLibraries(&binary)

        print("Writing revised MachO...")
        try FileManager.default.removeItem(at: macho)
        try binary.write(to: macho)
    }

    /// Redirects iOS-only @rpath Swift libs (libswiftUIKit) at their Mac Catalyst paths.
    ///
    /// - Parameter binary: The Mach-O bytes to rewrite.
    /// - Throws: Load-command rewrite failures.
    static func replaceLibraries(_ binary: inout Data) throws {
        let dylibsToReplace = ["libswiftUIKit"]

        for dylib in dylibsToReplace {
            let rpathDylib = "@rpath/\(dylib).dylib"
            let libDylib = "/System/iOSSupport/usr/lib/swift/\(dylib).dylib"

            // 1. Check if dylib LC exists
            // 2. If it exists, take notes of its command type and dylib struct
            // 3. Replace existing LC with new dylib path

            try replaceLibrary(&binary, rpathDylib, libDylib)
        }
    }

    /// Swaps one load command's dylib path, keeping size accounting exact (8-byte
    /// aligned, NUL-terminated) so later commands are not shifted.
    ///
    /// - Parameter binary: The Mach-O bytes to rewrite.
    /// - Parameter rpath: The @rpath to find.
    /// - Parameter lib: The absolute replacement path.
    /// - Throws: Load-command rewrite failures.
    static func replaceLibrary(_ binary: inout Data, _ rpath: String, _ lib: String) throws {
        var dylibCommandType: UInt32 = 0
        var oldDylib: dylib?

        try replaceLastCommand(&binary, satisfy: {commandData, shouldSwap in
            // Perform steps 1-2
            let loadCommand = commandData.extract(load_command.self,
                                                  offset: commandData.startIndex,
                                                  swap: shouldSwap ? swapLoadCommand:nil)
            if ![LC_LOAD_WEAK_DYLIB, UInt32(LC_LOAD_DYLIB)].contains(loadCommand.cmd) {
                return false
            }
            let dylibCommand = commandData.extract(dylib_command.self,
                                                   offset: commandData.startIndex,
                                                   swap: shouldSwap ? swapDylibCommand:nil)
            if String(data: commandData,
                      offset: commandData.startIndex,
                      commandSize: Int(dylibCommand.cmdsize),
                      loadCommandString: dylibCommand.dylib.name) != rpath {
                return false
            }
            dylibCommandType = dylibCommand.cmd
            oldDylib = dylibCommand.dylib
            return true

        }, with: {shouldSwap in
            guard var newDylib = oldDylib else {
                // dylib with given rpath was not found in binary
                return nil
            }

            print("Found \(rpath) in binary")

            // Perform step 3
            let dylibCommandFixedSize = MemoryLayout<dylib_command>.size
            let stringLength = lib.lengthOfBytes(using: String.Encoding.utf8)
            // Align to 8 bytes, leave at least 1 zero for C-style string ending
            let padding = 8 - (stringLength % 8)
            let newDylibCommandSize = dylibCommandFixedSize + stringLength + padding

            newDylib.name = lc_str(offset: UInt32(dylibCommandFixedSize))
            var command = dylib_command(cmd: dylibCommandType,
                                        cmdsize: UInt32(newDylibCommandSize),
                                        dylib: newDylib)
            guard let stringData = lib.data(using: String.Encoding.utf8) else {
                print("Failed to replace dylib command: unrecognized character in target path")
                return nil
            }
            if shouldSwap {
                swapDylibCommand(&command, NX_BigEndian)
            }
            var commandData = Data(bytes: &command, count: dylibCommandFixedSize)
            commandData.append(stringData)
            commandData.append(Data(count: padding))
            return commandData
        }, atEnd: false)
    }

    /// Replaces the iOS/macOS version command with a Mac Catalyst build-version
    /// command (minOS 11, SDK 14), appended at the end of the command list.
    ///
    /// - Parameter binary: The Mach-O bytes to rewrite.
    /// - Throws: Load-command rewrite failures.
    static func replaceVersionCommand(_ binary: inout Data) throws {

        var macCatalystCommand = build_version_command(cmd: UInt32(LC_BUILD_VERSION),
                                                       cmdsize: 24,
                                                       platform: UInt32(PLATFORM_MACCATALYST),
                                                       minos: 0x000b0000,
                                                       sdk: 0x000e0000,
                                                       ntools: 0)

        try replaceLastCommand(&binary, satisfy: {data, shouldSwap in
            let loadCommand = data.extract(load_command.self,
                                           offset: data.startIndex,
                                           swap: shouldSwap ? swapLoadCommand:nil)
            return [UInt32(LC_VERSION_MIN_IPHONEOS),
                    UInt32(LC_VERSION_MIN_MACOSX),
                    UInt32(LC_BUILD_VERSION)]
                .contains(loadCommand.cmd)

        }, with: {shouldSwap in
            if shouldSwap {
                swapBuildVersionCommand(&macCatalystCommand, NX_BigEndian)
            }
            return Data(bytes: &macCatalystCommand, count: MemoryLayout<build_version_command>.size)
        }, atEnd: true)
    }

    /// Replaces the last matching load command and rebalances sizeofcmds, shifting the
    /// following commands (zero-fill when shrinking; overlap check when growing).
    ///
    /// - Parameter binary: The Mach-O bytes to rewrite.
    /// - Parameter isTargetCommand: Matches the command bytes to replace.
    /// - Parameter getNewCommandData: Builds the replacement for the matched command.
    /// - Parameter shouldAppend: When true the replacement goes last, else first.
    /// - Throws: `OphanimError.appCorrupted` when the command table is inconsistent.
    static func replaceLastCommand(_ binary: inout Data,
                                   satisfy isTargetCommand: (Data, Bool) -> Bool,
                                   with getNewCommandData: (Bool) -> Data?,
                                   atEnd shouldAppend: Bool) throws {
        let headerSize = MemoryLayout<mach_header_64>.size
        var header = binary.extract(mach_header_64.self)
        var shouldSwap = false

        var oldCommandStart = headerSize
        var oldCommandSize: UInt32 = 0

        let movedCommandsEnd = try iterateLoadCommands(binary: binary) { offset, needSwap in
            let loadCommand = binary.extract(load_command.self,
                                             offset: offset,
                                             swap: needSwap ? swapLoadCommand:nil)
            if isTargetCommand(binary[offset ..< offset+Int(loadCommand.cmdsize)], needSwap) {
                oldCommandStart = offset
                oldCommandSize = loadCommand.cmdsize
                shouldSwap = needSwap
            }
            return false
        }
        if movedCommandsEnd != headerSize + Int(header.sizeofcmds) {
            print("Error while replacing load command: end of commands mismatch")
        }

        let oldCommandEnd = oldCommandStart + Int(oldCommandSize)
        guard let newCommandData = getNewCommandData(shouldSwap) else {
            return
        }
        let newCommandSize = UInt32(newCommandData.count)

        var resultingCommandsData = binary[oldCommandEnd..<movedCommandsEnd]
        if shouldAppend {
            resultingCommandsData.append(newCommandData)
        } else {
            resultingCommandsData.insert(contentsOf: newCommandData,
                                         at: resultingCommandsData.startIndex)
        }

        let injectionEnd = movedCommandsEnd - Int(oldCommandSize) + Int(newCommandSize)
        if injectionEnd > movedCommandsEnd {
            if let nonZero = binary[movedCommandsEnd ..< injectionEnd].first(where: {$0 != 0}) {
                print("Non zero value \(nonZero) found after load commands. Injection may overlap data section")
            }
        } else {
            binary.replaceSubrange(injectionEnd ..< movedCommandsEnd,
                                   with: Data(count: movedCommandsEnd - injectionEnd))
        }
        binary.replaceSubrange(oldCommandStart..<injectionEnd, with: resultingCommandsData)

        // Write new header data
        header.sizeofcmds -= oldCommandSize
        header.sizeofcmds += newCommandSize
        let newHeaderData = Data(bytes: &header, count: headerSize)
        binary.replaceSubrange(0..<headerSize, with: newHeaderData)
    }

    /// Walks the load-command table, evaluating each entry. Stops early when the
    /// closure returns true.
    ///
    /// - Parameter binary: The (already slim) Mach-O bytes.
    /// - Parameter evaluate: Per-command check (offset, byte-swapped flag); true stops.
    /// - Returns: The offset just past the last visited command.
    /// - Throws: `OphanimError.appCorrupted` when the table overruns the file.
    static func iterateLoadCommands(binary: Data, _ evaluate: (Int, Bool) -> Bool) throws -> Int {
        let headerSize = MemoryLayout<mach_header_64>.size
        var header = binary.extract(mach_header_64.self)
        var offset = headerSize
        let shouldSwap = header.magic == MH_CIGAM_64
        if  shouldSwap {
            swapMachHeader64(&header, NXHostByteOrder())
            print("Slim Mach-O has reversed byte order")
        }

        let allCommandsEnd = headerSize + Int(header.sizeofcmds)
        if allCommandsEnd >= binary.count || allCommandsEnd <= headerSize {
            print("Cannot iterate load commands: Mach-O file is corrupted(-1)")
            throw OphanimError.appCorrupted
        }
        for index in 0..<header.ncmds {
            let loadCommand = binary.extract(load_command.self,
                                             offset: offset,
                                             swap: shouldSwap ? swapLoadCommand:nil)
            let commandEnd = offset + Int(loadCommand.cmdsize)
            if commandEnd > allCommandsEnd || commandEnd <= offset {
                print("Cannot iterate load commands: Mach-O file is corrupted(\(index))")
                throw OphanimError.appCorrupted
            }
            let terminated = evaluate(offset, shouldSwap)
            offset = commandEnd
            if terminated {
                break
            }
        }
        return offset
    }

    /// Strip to the slim ARM64 slice, then scan load commands for the first one whose `cmd` matches
    /// `command` and evaluate `test` against its byte range. Returns false if no such command exists.
    private static func firstLoadCommand(atURL url: URL, command: UInt32,
                                         test: (_ binary: Data, _ offset: Int, _ shouldSwap: Bool) -> Bool) throws -> Bool {
        var binary = try Data(contentsOf: url)
        try stripBinary(&binary)
        var result = false
        _ = try iterateLoadCommands(binary: binary) { offset, shouldSwap in
            let loadCommand = binary.extract(load_command.self,
                                             offset: offset,
                                             swap: shouldSwap ? swapLoadCommand:nil)
            if loadCommand.cmd == command {
                result = test(binary, offset, shouldSwap)
                return true
            }
            return false
        }
        return result
    }

    /// True when the LC_ENCRYPTION_INFO_64 cryptid is set (FairPlay still on).
    ///
    /// - Parameter url: The Mach-O file.
    /// - Returns: Whether the binary is encrypted.
    /// - Throws: Read/strip/iteration failures.
    static func isMachoEncrypted(atURL url: URL) throws -> Bool {
        try firstLoadCommand(atURL: url, command: UInt32(LC_ENCRYPTION_INFO_64)) { binary, offset, shouldSwap in
            let infoCommand = binary.extract(encryption_info_command_64.self,
                                             offset: offset,
                                             swap: shouldSwap ? swapEncryptionCommand64:nil)
            return infoCommand.cryptid != 0
        }
    }

    /// True when a Catalyst platform marker is present (same any-match rule as
    /// launch: converted binaries carry iOS first, Catalyst second).
    ///
    /// - Parameter url: The Mach-O file.
    /// - Returns: Whether the binary has a Catalyst slice.
    /// - Throws: Read/strip/iteration failures.
    static func isMachoValidArch(_ url: URL) throws -> Bool {
        try firstLoadCommand(atURL: url, command: UInt32(LC_BUILD_VERSION)) { binary, offset, shouldSwap in
            let versionCommand = binary.extract(build_version_command.self,
                                                offset: offset,
                                                swap: shouldSwap ? swapBuildVersionCommand:nil)
            return versionCommand.platform == PLATFORM_MACCATALYST
        }
    }

    // MARK: - Inspect

    /// Reports whether a dylib/framework file is installable: Mach-O check, FairPlay
    /// flag, Catalyst slice, and blocker summary. Read-only; never throws.
    ///
    /// - Parameter url: The file to inspect.
    /// - Returns: Report dict (loadable, reason, encrypted, validArchitecture, ...).
    /// - Throws: Nothing (all failures fold into the report); `throws` stays for `try?` callers.
    static func inspect(_ url: URL) throws -> [String: Any] {
        var report: [String: Any] = ["path": url.path]

        // A framework is loadable if its binary is: resolve the binary FIRST,
        // because reading a directory URL as data always fails (which used to
        // make every framework report "not a readable file" before reaching here).
        let isFramework = url.pathExtension == "framework"
        let binaryURL: URL
        if isFramework {
            let bundle = Bundle(url: url)
            guard let exe = bundle?.executableURL, FileManager.default.fileExists(atPath: exe.path) else {
                report["loadable"] = false
                report["reason"] = "framework has no readable executable"
                return report
            }
            binaryURL = exe
        } else {
            binaryURL = url
        }
        report["isFramework"] = isFramework
        if isFramework { report["binary"] = binaryURL.path }

        guard let data = try? Data(contentsOf: binaryURL) else {
            report["loadable"] = false
            report["reason"] = "not a readable file"
            return report
        }

        guard data.count >= 4 else {
            report["loadable"] = false
            report["reason"] = "empty file"
            return report
        }
        // Little-endian 4-byte magic: MH_MAGIC_64, its byte-swapped form, or a
        // fat binary (universal tweaks are plausible artistically). Previously this
        // compared a 2-byte value against 4-byte constants, which rejected every
        // file including valid arm64 binaries (proven vs the host app binary).
        let magicLE = UInt32(data[0]) | (UInt32(data[1]) << 8)
            | (UInt32(data[2]) << 16) | (UInt32(data[3]) << 24)
        let isMachO = magicLE == 0xFEEDFACF || magicLE == 0xCFFAEDFE
            || magicLE == 0xCAFEBABE || magicLE == 0xBEBAFECA
        report["isMachO"] = isMachO
        guard isMachO else {
            report["loadable"] = false
            report["reason"] = "not a Mach-O file (a script or data file was given)"
            return report
        }

        if let encrypted = try? isMachoEncrypted(atURL: binaryURL) {
            report["encrypted"] = encrypted
        }
        if let valid = try? isMachoValidArch(binaryURL) {
            report["validArchitecture"] = valid
        }

        // The load commands are walked with the engine's own iterator, so a change to what the
        // loader looks for cannot leave this reporting something different. The iterator
        // stops when the closure returns true, so the counter returns false to visit all.
        var commandCount = 0
        _ = try? iterateLoadCommands(binary: data) { _, _ in
            commandCount += 1
            return false
        }
        report["loadCommandCount"] = commandCount

        // The decision the caller actually needs.
        var blockers: [String] = []
        if (report["encrypted"] as? Bool) == true { blockers.append("encrypted (FairPlay)") }
        if (report["validArchitecture"] as? Bool) == false { blockers.append("not a loadable arm64 slice") }
        report["loadable"] = blockers.isEmpty
        report["reason"] = blockers.isEmpty ? "ok" : blockers.joined(separator: ", ")
        return report
    }
}

// MARK: - Host-order byte swap
//
// Replaces the libc swap_* family (swap_fat_header, swap_fat_arch,
// swap_mach_header_64, swap_load_command, swap_dylib_command,
// swap_build_version_command, swap_encryption_command_64 — deprecated in
// macOS 13, "No longer supported"). Same signatures as Data.extract's swap
// parameter, same contract as the libc originals: each function
// unconditionally byte-swaps every integer field, so call sites pass them
// only for opposite-endian file data (big-endian CIGAM/FAT_CIGAM input on
// little-endian hosts, or host-built structs being written back big-endian).
// Implemented with FixedWidthInteger.byteSwapped (signed fields included).

fileprivate func swapFatHeader(_ p: UnsafeMutablePointer<fat_header>, _ order: NXByteOrder) {
    p.pointee.magic = p.pointee.magic.byteSwapped
    p.pointee.nfat_arch = p.pointee.nfat_arch.byteSwapped
}

fileprivate func swapFatArch(_ p: UnsafeMutablePointer<fat_arch>, _ order: NXByteOrder) {
    p.pointee.cputype = p.pointee.cputype.byteSwapped
    p.pointee.cpusubtype = p.pointee.cpusubtype.byteSwapped
    p.pointee.offset = p.pointee.offset.byteSwapped
    p.pointee.size = p.pointee.size.byteSwapped
    p.pointee.align = p.pointee.align.byteSwapped
}

fileprivate func swapMachHeader64(_ p: UnsafeMutablePointer<mach_header_64>, _ order: NXByteOrder) {
    p.pointee.magic = p.pointee.magic.byteSwapped
    p.pointee.cputype = p.pointee.cputype.byteSwapped
    p.pointee.cpusubtype = p.pointee.cpusubtype.byteSwapped
    p.pointee.filetype = p.pointee.filetype.byteSwapped
    p.pointee.ncmds = p.pointee.ncmds.byteSwapped
    p.pointee.sizeofcmds = p.pointee.sizeofcmds.byteSwapped
    p.pointee.flags = p.pointee.flags.byteSwapped
    p.pointee.reserved = p.pointee.reserved.byteSwapped
}

fileprivate func swapLoadCommand(_ p: UnsafeMutablePointer<load_command>, _ order: NXByteOrder) {
    p.pointee.cmd = p.pointee.cmd.byteSwapped
    p.pointee.cmdsize = p.pointee.cmdsize.byteSwapped
}

fileprivate func swapDylibCommand(_ p: UnsafeMutablePointer<dylib_command>, _ order: NXByteOrder) {
    p.pointee.cmd = p.pointee.cmd.byteSwapped
    p.pointee.cmdsize = p.pointee.cmdsize.byteSwapped
    p.pointee.dylib.name.offset = p.pointee.dylib.name.offset.byteSwapped
    p.pointee.dylib.timestamp = p.pointee.dylib.timestamp.byteSwapped
    p.pointee.dylib.current_version = p.pointee.dylib.current_version.byteSwapped
    p.pointee.dylib.compatibility_version = p.pointee.dylib.compatibility_version.byteSwapped
}

fileprivate func swapBuildVersionCommand(_ p: UnsafeMutablePointer<build_version_command>, _ order: NXByteOrder) {
    p.pointee.cmd = p.pointee.cmd.byteSwapped
    p.pointee.cmdsize = p.pointee.cmdsize.byteSwapped
    p.pointee.platform = p.pointee.platform.byteSwapped
    p.pointee.minos = p.pointee.minos.byteSwapped
    p.pointee.sdk = p.pointee.sdk.byteSwapped
    p.pointee.ntools = p.pointee.ntools.byteSwapped
}

fileprivate func swapEncryptionCommand64(_ p: UnsafeMutablePointer<encryption_info_command_64>, _ order: NXByteOrder) {
    p.pointee.cmd = p.pointee.cmd.byteSwapped
    p.pointee.cmdsize = p.pointee.cmdsize.byteSwapped
    p.pointee.cryptoff = p.pointee.cryptoff.byteSwapped
    p.pointee.cryptsize = p.pointee.cryptsize.byteSwapped
    p.pointee.cryptid = p.pointee.cryptid.byteSwapped
    p.pointee.pad = p.pointee.pad.byteSwapped
}
