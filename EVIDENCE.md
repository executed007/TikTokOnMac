# How PlayCover runs iOS apps on a Mac

Target: `/Applications/PlayCover.app` 3.1.0, `Contents/MacOS/PlayCover`, arm64,
SHA-256 `82c73cc8ecdad4e1b5f47696413613f9d223bcb57833f1ae6a6145642cd6c8a7`.
Method: static analysis only (Ghidra through REA, `otool -tV`, `strings`, `xxd`).
Nothing below was observed at runtime; PlayCover had no apps installed on this Mac.

## Summary

PlayCover does not emulate anything. Apple silicon Macs run arm64 iOS code natively,
and macOS already ships the iOS frameworks for Mac Catalyst under `/System/iOSSupport`.
PlayCover edits a decrypted iOS app so the loader treats it as a Mac Catalyst app,
re-signs it, and injects a helper library for input and device spoofing.

## Observed

| # | Finding | Where |
|---|---------|-------|
| 1 | Install steps, in UI order: unzip the .ipa, copy the app, create a wrapper, install PlayTools, sign, add to library | String keys `playapp.install.unzip`, `.copy`, `.createWrapper`, `.installPlayTools`, `.signing`, `.addToLib` and their `en.lproj` texts |
| 2 | The Mach-O conversion routine logs five stages: "Converting MachO at ", "Stripping MachO...", "Replacing version command...", "Replacing instances of @rpath dylibs...", "Writing revised MachO..." | String references at `0x100033ad0`, `0x100033bac`, `0x100033c1c`, `0x100033ce0`, `0x100033d8c` |
| 3 | The replacement version command is a 24-byte constant: `cmd 0x32` (LC_BUILD_VERSION), `cmdsize 0x18`, `platform 6` (Mac Catalyst), `minos 0x000b0000` (11.0), `sdk 0x000e0000` (14.0), `ntools 0` | Loaded at `0x100033c4c`–`0x100033c60` from `0x1001e5230`; bytes read with `xxd -s 0x1e5230 -l 24 -e` |
| 4 | The load-command walker checks the 64-bit magic `0xfeedfacf` and compares each command against `0x32` (LC_BUILD_VERSION) | `0x1000340c0`, `0x100034138` |
| 5 | A second walker compares against `0x2c` (LC_ENCRYPTION_INFO_64); the app shows "This app is encrypted! Please use a decrypted IPA." | `0x100032814`; `error.appEncrypted` in `en.lproj` |
| 6 | Fat binaries are thinned: "Found ARM64 arch in fat binary" next to `0xcafebabe` checks | `0x10003237c`, string in the same code region |
| 7 | `@rpath` Swift libraries are redirected to `/System/iOSSupport/usr/lib/swift/` | `0x1000338c0` |
| 8 | PlayTools is injected as a load command for `@executable_path/Frameworks/PlayTools.dylib`; the injector knows `LC_LOAD_DYLIB`, `LC_LOAD_WEAK_DYLIB`, `LC_REEXPORT_DYLIB`, `LC_LOAD_UPWARD_DYLIB` | `0x100016350`; strings "Copying PlayTools to Frameworks", "Need a dylib or framework file to inject" |
| 9 | Signing shells out to `/usr/bin/codesign`, once with `--preserve-metadata=entitlements` | `0x1000a8cec`, `0x1000a8e2c`, `0x1000a8e40` and four other call sites |
| 10 | Entitlements are generated per app: `com.apple.security.app-sandbox`, device and file entitlements, and a `com.apple.security.temporary-exception.sbpl` built from "(allow file* ...)" / "(deny file* ...)" rules | Strings in the `Entitlements` class region; `Resources/default.yaml` lists denied paths such as `/bin/bash` and `/var/lib/cydia` |
| 11 | `com.apple.quarantine` is referenced by the installer | `0x1000232e4` |
| 12 | The bundled `PlayTools.framework` is itself a Mac Catalyst binary with the same version command (platform 6, minos 11.0, sdk 14.0) and contains swizzling, touch synthesis and jailbreak-check classes | `otool -l`; strings `PTSwizzleLoader`, `PTFakeMetaTouch`, `Toucher`, `isJailbroken`, `hw.machine` |
| 13 | Optional "package signing" mode asks the user to disable SIP and set `amfi_get_out_of_my_way=0x1` | `configSigning.*` strings; `/usr/bin/csrutil` at `0x100038190` |
| 14 | Launch goes through `NSWorkspace` (`openApplicationAtURL:configuration:completionHandler:`); a debug path builds `/usr/bin/lldb -o run <path>` | Selector string; `0x1000a7df8` |

REA Evidence IDs: procedure search `ev_cf5bb9e266bcbd7f9c26f6c84cb4480692cd72b2c97e55737a948dea5a0efbeb`,
`LC_LOAD_DYLIB` trace `ev_4010f85622a2f4988a8ea7f4bb206a6ddc704cb0650e40d5ebb1e2347f83abfb`,
`/usr/bin/codesign` trace `ev_bd256099cc4d0e64bb2c1da345e18dbf38fda7669b40f8fd98fe3b16d8ef54d7`.

## Inferred

- The order of operations inside the installer follows the order of its progress
  strings; the call sequence was not traced instruction by instruction.
- Finding 4 handles `LC_BUILD_VERSION`; older `LC_VERSION_MIN_IPHONEOS` commands are
  assumed to be replaced the same way. No direct comparison against `0x25` was found
  in that routine.
- "Stripping MachO..." most likely removes the existing code signature before re-signing.

## Unknown

- What "Creating app wrapper..." writes on disk.
- Which entitlements are applied to which app, and the exact `codesign` arguments.
- Runtime behaviour of PlayTools (it was only inventoried, not analysed).
- Ghidra recovered no Swift function names (the binary is stripped), so routines are
  identified by address and by the strings they reference.

## What catalyst-runner reproduces

| PlayCover | catalyst-runner |
|-----------|-----------------|
| Unzip .ipa, copy app (1) | Same, staged in a temporary folder |
| Thin fat binaries (6) | `MachO.thinned` |
| Reject encrypted binaries (5) | `MachO.isEncrypted`, cryptid check |
| Replace version command with the constant in (3) | `MachO.replacingVersionCommand`, same six values |
| `codesign`, quarantine removal (9, 11) | Ad hoc `codesign --force --deep --sign -`, `xattr -dr` |
| Launch through LaunchServices (14) | `/usr/bin/open` |

Left out on purpose: PlayTools injection and everything it does (keymapping, touch
synthesis, device spoofing, hiding jailbreak-style paths), generated sandbox
entitlements, `@rpath` rewriting, and the SIP/AMFI signing mode.
