import Foundation

// Unit tests for MachO.swift on synthetic images. Run by build.sh.

var failures = 0
func check(_ condition: @autoclosure () throws -> Bool, _ name: String) {
    let passed = (try? condition()) ?? false
    print("\(passed ? "ok  " : "FAIL") \(name)")
    if !passed { failures += 1 }
}

func words(_ values: [UInt32]) -> Data {
    var data = Data()
    values.forEach { data.append(u32: $0) }
    return data
}

/// A thin arm64 image: header, the given load commands, zero padding up to `contentOffset`,
/// then 64 bytes of "code". One __TEXT segment with one section points at that code.
func image(versionCommand: Data, extra: [Data] = [], contentOffset: UInt32 = 512) -> Data {
    var segment = words([MachO.lcSegment64, 72 + 80])
    segment.append(Data(count: 64))                       // segname..flags, zeroed
    segment.setU32(1, at: 64)                             // nsects
    var section = Data(count: 80)
    section.setU32(64, at: 40)                            // size
    section.setU32(contentOffset, at: 48)                 // offset
    segment.append(section)
    let commands = [segment, versionCommand] + extra
    let size = commands.reduce(0) { $0 + $1.count }
    var data = words([MachO.magic64, MachO.cpuArm64, 0, 2, UInt32(commands.count), UInt32(size), 0, 0])
    commands.forEach { data.append($0) }
    data.append(Data(count: Int(contentOffset) - data.count))
    data.append(Data(repeating: 0xAA, count: 64))
    return data
}

let iosBuild = words([MachO.lcBuildVersion, 32, 2, 0x000e_0000, 0x0011_0000, 1, 3, 0x0300_0000])   // iOS 14, one tool
let iosVersionMin = words([MachO.lcVersionMinIOS, 16, 0x000c_0000, 0x000e_0000])
let trailing = words([0x1b, 24, 1, 2, 3, 4])                                                       // LC_UUID
func encryption(cryptid: UInt32) -> Data { words([MachO.lcEncryptionInfo64, 24, 0x4000, 0x1000, cryptid, 0]) }

// LC_BUILD_VERSION (iOS) -> Mac Catalyst
do {
    let source = image(versionCommand: iosBuild, extra: [trailing])
    let output = try MachO.replacingVersionCommand(source)
    check(try MachO.buildVersion(output) == MachO.catalyst, "LC_BUILD_VERSION becomes Mac Catalyst 11.0 / sdk 14.0")
    check(try MachO.commands(output).map(\.cmd) == [MachO.lcSegment64, MachO.lcBuildVersion, 0x1b], "command order kept")
    check(output.u32(20) == source.u32(20) - 8, "sizeofcmds shrinks by the dropped tool entry")
    check(output.count == source.count && output.suffix(64) == source.suffix(64), "file size and code untouched")
    check(output.slice(32 + Int(output.u32(20)) ..< 512).allSatisfy { $0 == 0 }, "stale command bytes zeroed")
    check(try MachO.commands(output).last.map { output.slice($0.range) } == trailing, "following command moved intact")
    check(try MachO.replacingVersionCommand(output) == output, "conversion is idempotent")
} catch { check(false, "build-version conversion threw \(error)") }

// LC_VERSION_MIN_IPHONEOS (16 bytes) -> LC_BUILD_VERSION (24 bytes)
do {
    let source = image(versionCommand: iosVersionMin, extra: [trailing])
    let output = try MachO.replacingVersionCommand(source)
    check(try MachO.buildVersion(output) == MachO.catalyst, "LC_VERSION_MIN_IPHONEOS replaced")
    check(output.u32(20) == source.u32(20) + 8 && output.u32(16) == source.u32(16), "table grows into header padding")
    let tight = image(versionCommand: iosVersionMin, contentOffset: UInt32(32 + 152 + 16))
    check((try? MachO.replacingVersionCommand(tight)) == nil, "refuses to overwrite code when there is no padding")
} catch { check(false, "version-min conversion threw \(error)") }

// Encryption
check(try MachO.isEncrypted(image(versionCommand: iosBuild, extra: [encryption(cryptid: 1)])), "cryptid 1 detected as encrypted")
check(try !MachO.isEncrypted(image(versionCommand: iosBuild, extra: [encryption(cryptid: 0)])), "cryptid 0 is not encrypted")
do {
    _ = try MachO.convertedToCatalyst(image(versionCommand: iosBuild, extra: [encryption(cryptid: 1)]))
    check(false, "encrypted binary rejected")
} catch MachO.Failure.encrypted { check(true, "encrypted binary rejected") } catch { check(false, "encrypted binary rejected") }

// Fat binaries are thinned to arm64
do {
    let arm = image(versionCommand: iosBuild)
    var fat = Data()
    for value in [MachO.fatMagic, 2, 0x0100_0007, 3, 64, 16, 0, MachO.cpuArm64, 0, 128, UInt32(arm.count), 0] as [UInt32] {
        fat.append(u32: value.byteSwapped)
    }
    fat.append(Data(count: 128 - fat.count))
    fat.append(arm)
    _ = try MachO.thinned(fat)
    check(try MachO.thinned(fat) == arm, "arm64 slice extracted from fat binary")
    check(try MachO.buildVersion(MachO.convertedToCatalyst(fat)) == MachO.catalyst, "fat binary converted")
    check(MachO.isMachO(fat) && MachO.isMachO(arm) && !MachO.isMachO(Data(count: 64)), "Mach-O detection")
} catch { check(false, "fat handling threw \(error)") }

// Helper library injection
do {
    let source = image(versionCommand: iosBuild)
    let path = "@executable_path/Frameworks/RunnerShim.dylib"
    let output = try MachO.addingDylib(source, path: path)
    let added = try MachO.commands(output).last!
    check(added.cmd == MachO.lcLoadDylib && added.range.count % 8 == 0, "LC_LOAD_DYLIB appended")
    check(output.slice(added.range.lowerBound + 24 ..< added.range.upperBound).prefix(path.utf8.count) == Data(path.utf8), "dylib path stored")
    check(output.u32(16) == source.u32(16) + 1 && output.suffix(64) == source.suffix(64), "command count bumped, code untouched")
    check(try MachO.addingDylib(output, path: path) == output, "injection is idempotent")
    let tight = image(versionCommand: iosBuild, contentOffset: UInt32(32 + 152 + 32 + 16))
    check((try? MachO.addingDylib(tight, path: path)) == nil, "injection refused without header padding")
} catch { check(false, "dylib injection threw \(error)") }

// Corruption
do {
    var broken = image(versionCommand: iosBuild)
    broken.setU32(0xffff, at: 20)
    check((try? MachO.commands(broken)) == nil, "oversized sizeofcmds rejected")
    check((try? MachO.thinned(Data("not a binary at all, just some text".utf8))) == nil, "non Mach-O rejected")
}

print(failures == 0 ? "All tests passed" : "\(failures) test(s) failed")
exit(failures == 0 ? 0 : 1)
