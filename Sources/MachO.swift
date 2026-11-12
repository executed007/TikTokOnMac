import Foundation

/// Mach-O rewriting that makes an arm64 iOS binary loadable as a Mac Catalyst
/// binary on Apple silicon. Mirrors what PlayCover's `Macho` class does (see
/// EVIDENCE.md): thin to arm64, refuse encrypted binaries, and replace the
/// version load command with LC_BUILD_VERSION { platform: Mac Catalyst }.
enum MachO {
    enum Failure: Error, CustomStringConvertible {
        case notMachO, noArm64Slice, bigEndian, corrupted(String), encrypted, noHeaderSpace

        var description: String {
            switch self {
            case .notMachO: "not a Mach-O file"
            case .noArm64Slice: "no arm64 slice in fat binary"
            case .bigEndian: "big-endian Mach-O is not supported"
            case .corrupted(let why): "Mach-O file is corrupted (\(why))"
            case .encrypted: "binary is FairPlay-encrypted; a decrypted app is required"
            case .noHeaderSpace: "no room after load commands for the new version command"
            }
        }
    }

    struct BuildVersion: Equatable {
        var platform: UInt32
        var minOS: UInt32
        var sdk: UInt32
    }

    // <mach-o/loader.h>
    static let magic64: UInt32 = 0xfeed_facf
    static let fatMagic: UInt32 = 0xcafe_babe
    static let cpuArm64: UInt32 = 0x0100_000c
    static let lcLoadDylib: UInt32 = 0xc
    static let lcSegment64: UInt32 = 0x19
    static let lcVersionMinMacOS: UInt32 = 0x24
    static let lcVersionMinIOS: UInt32 = 0x25
    static let lcEncryptionInfo64: UInt32 = 0x2c
    static let lcVersionMinTvOS: UInt32 = 0x2f
    static let lcVersionMinWatchOS: UInt32 = 0x30
    static let lcBuildVersion: UInt32 = 0x32
    static let platformMacCatalyst: UInt32 = 6
    static let headerSize = 32

    /// The exact command PlayCover 3.1.0 writes: Mac Catalyst, minos 11.0, sdk 14.0, no tools.
    static let catalyst = BuildVersion(platform: platformMacCatalyst, minOS: 0x000b_0000, sdk: 0x000e_0000)

    static func isMachO(_ data: Data) -> Bool {
        guard data.count >= headerSize else { return false }
        let magic = data.u32(0)
        return magic == magic64 || magic.byteSwapped == fatMagic
    }

    /// Returns the arm64 slice of a fat binary, or the data itself if already thin.
    static func thinned(_ data: Data) throws -> Data {
        guard data.count >= headerSize else { throw Failure.notMachO }
        let magic = data.u32(0)
        if magic == magic64 {
            guard data.u32(4) == cpuArm64 else { throw Failure.noArm64Slice }
            return data
        }
        if magic == magic64.byteSwapped { throw Failure.bigEndian }
        guard magic.byteSwapped == fatMagic else { throw Failure.notMachO }
        let count = Int(data.u32(4).byteSwapped)            // fat headers are big-endian
        guard count < 64, data.count >= 8 + count * 20 else { throw Failure.corrupted("fat header") }
        for index in 0..<count {
            let arch = 8 + index * 20
            guard data.u32(arch).byteSwapped == cpuArm64 else { continue }
            let offset = Int(data.u32(arch + 8).byteSwapped), size = Int(data.u32(arch + 12).byteSwapped)
            guard offset + size <= data.count else { throw Failure.corrupted("fat slice") }
            return try thinned(Data(data[data.startIndex + offset ..< data.startIndex + offset + size]))
        }
        throw Failure.noArm64Slice
    }

    struct Command {
        let cmd: UInt32
        let range: Range<Int>
    }

    static func commands(_ thin: Data) throws -> [Command] {
        guard thin.count >= headerSize, thin.u32(0) == magic64 else { throw Failure.notMachO }
        let end = headerSize + Int(thin.u32(20))
        guard end <= thin.count else { throw Failure.corrupted("sizeofcmds") }
        var result: [Command] = [], offset = headerSize
        for _ in 0..<thin.u32(16) {
            guard offset + 8 <= end else { throw Failure.corrupted("load command header") }
            let size = Int(thin.u32(offset + 4))
            guard size >= 8, size % 8 == 0, offset + size <= end else { throw Failure.corrupted("cmdsize") }
            result.append(Command(cmd: thin.u32(offset), range: offset ..< offset + size))
            offset += size
        }
        return result
    }

    /// True when LC_ENCRYPTION_INFO_64 has a non-zero cryptid (App Store FairPlay).
    static func isEncrypted(_ thin: Data) throws -> Bool {
        try commands(thin).contains { $0.cmd == lcEncryptionInfo64 && $0.range.count >= 20 && thin.u32($0.range.lowerBound + 16) != 0 }
    }

    static func buildVersion(_ thin: Data) throws -> BuildVersion? {
        guard let command = try commands(thin).first(where: { $0.cmd == lcBuildVersion }) else { return nil }
        let base = command.range.lowerBound
        return BuildVersion(platform: thin.u32(base + 8), minOS: thin.u32(base + 12), sdk: thin.u32(base + 16))
    }

    /// Replaces every version command (LC_VERSION_MIN_* and LC_BUILD_VERSION) with one
    /// LC_BUILD_VERSION for `target`, keeping the other load commands in order.
    static func replacingVersionCommand(_ thin: Data, with target: BuildVersion = catalyst) throws -> Data {
        let versionCommands: Set<UInt32> = [lcVersionMinMacOS, lcVersionMinIOS, lcVersionMinTvOS, lcVersionMinWatchOS, lcBuildVersion]
        let old = try commands(thin)
        var replacement = Data()
        for value in [lcBuildVersion, 24, target.platform, target.minOS, target.sdk, 0] { replacement.append(u32: value) }

        var table = Data(), inserted = false
        for command in old {
            if versionCommands.contains(command.cmd) {
                if !inserted { table.append(replacement); inserted = true }
            } else {
                table.append(thin.slice(command.range))
            }
        }
        if !inserted { table.append(replacement) }

        let oldSize = Int(thin.u32(20))
        if table.count > oldSize {
            // Growing (e.g. 16-byte LC_VERSION_MIN -> 24 bytes) must fit in the header padding.
            guard headerSize + table.count <= firstContentOffset(thin, old) else { throw Failure.noHeaderSpace }
        }
        var output = thin
        let start = output.startIndex + headerSize
        output.replaceSubrange(start ..< start + table.count, with: table)
        if table.count < oldSize {
            output.replaceSubrange(start + table.count ..< start + oldSize, with: Data(count: oldSize - table.count))
        }
        let count = old.filter { !versionCommands.contains($0.cmd) }.count + 1
        output.setU32(UInt32(count), at: 16)
        output.setU32(UInt32(table.count), at: 20)
        return output
    }

    /// Appends an LC_LOAD_DYLIB for `path` so dyld loads that library at launch.
    /// Returns the input unchanged if the binary already loads it.
    static func addingDylib(_ thin: Data, path: String) throws -> Data {
        let old = try commands(thin)
        let name = Data(path.utf8)
        for command in old where command.cmd == lcLoadDylib && command.range.count > 24 {
            let existing = thin.slice(command.range.lowerBound + 24 ..< command.range.upperBound)
            if existing.prefix(while: { $0 != 0 }) == name { return thin }
        }
        let size = (24 + name.count + 1 + 7) / 8 * 8
        var command = Data()
        for value in [lcLoadDylib, UInt32(size), 24, 2, 0x0001_0000, 0x0001_0000] { command.append(u32: value) }
        command.append(name)
        command.append(Data(count: size - command.count))

        let end = headerSize + Int(thin.u32(20))
        guard end + size <= firstContentOffset(thin, old) else { throw Failure.noHeaderSpace }
        var output = thin
        output.replaceSubrange(output.startIndex + end ..< output.startIndex + end + size, with: command)
        output.setU32(thin.u32(16) + 1, at: 16)
        output.setU32(thin.u32(20) + UInt32(size), at: 20)
        return output
    }

    /// Full conversion of one binary: thin, reject encrypted, retarget to Mac Catalyst.
    static func convertedToCatalyst(_ data: Data) throws -> Data {
        let thin = try thinned(data)
        if try isEncrypted(thin) { throw Failure.encrypted }
        return try replacingVersionCommand(thin)
    }

    /// Lowest file offset used by section contents; load commands may grow up to here.
    private static func firstContentOffset(_ thin: Data, _ commands: [Command]) -> Int {
        var lowest = thin.count
        for command in commands where command.cmd == lcSegment64 && command.range.count >= 72 {
            let base = command.range.lowerBound
            for index in 0..<Int(thin.u32(base + 64)) {
                let section = base + 72 + index * 80
                guard section + 80 <= command.range.upperBound else { break }
                let offset = Int(thin.u32(section + 48)), size = thin.u64(section + 40)
                if offset > 0, size > 0 { lowest = min(lowest, offset) }
            }
        }
        return lowest
    }
}

extension Data {
    func u32(_ offset: Int) -> UInt32 {
        var value: UInt32 = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { copyBytes(to: $0, from: startIndex + offset ..< startIndex + offset + 4) }
        return UInt32(littleEndian: value)
    }

    func u64(_ offset: Int) -> UInt64 { UInt64(u32(offset)) | UInt64(u32(offset + 4)) << 32 }

    func slice(_ range: Range<Int>) -> Data { self[startIndex + range.lowerBound ..< startIndex + range.upperBound] }

    mutating func append(u32 value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }

    mutating func setU32(_ value: UInt32, at offset: Int) {
        Swift.withUnsafeBytes(of: value.littleEndian) {
            replaceSubrange(startIndex + offset ..< startIndex + offset + 4, with: $0)
        }
    }
}
