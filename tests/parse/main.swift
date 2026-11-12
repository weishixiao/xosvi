// main.swift — 静态解析层自检（v7.18 系列）
//
// 为什么有这个东西：armor / crash.ips / package inspect(<dir>) 三套解析都是
// 手写字节解析（Mach-O load commands、.ips 头/正文、.app 目录），本机没有 swiftc，
// 真机 App 又必须重新出包才能跑，于是「写完没人执行过」。
// 这个自检在 macOS runner 上用真实文件把解析代码**跑一遍**：
//   · armor hardening / toolchain / diff  —— 拿系统里的真 Mach-O 二进制
//   · crash.ips parse                     —— 拿合成的 .ips（真机格式）夹具
//   · BundleAnatomy.inspect               —— 拿合成 .app 目录（真 Mach-O 当主二进制）
//
// 只读、不联网、不碰真机；任何一条断言失败，进程退出码非 0，CI 变红。

import Foundation
#if canImport(Darwin)
import Darwin
#endif

var failures = 0
var passes = 0

func expect(_ cond: Bool, _ label: String) {
    if cond {
        passes += 1
        print("  PASS  \(label)")
    } else {
        failures += 1
        print("  FAIL  \(label)")
    }
}

func section(_ name: String) { print("\n== \(name)") }

func dictOf(_ v: Any?) -> [String: Any]? { v as? [String: Any] }
func arrayOf(_ v: Any?) -> [Any]? { v as? [Any] }
func strOf(_ v: Any?) -> String? { v as? String }
func intOf(_ v: Any?) -> Int? {
    if let i = v as? Int { return i }
    if let n = v as? NSNumber { return n.intValue }
    return nil
}
func boolOf(_ v: Any?) -> Bool? { v as? Bool }

let tmpRoot = NSTemporaryDirectory() + "xosvi-parseselftest-\(UUID().uuidString)"
try? FileManager.default.createDirectory(atPath: tmpRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(atPath: tmpRoot) }

// 夹具：系统里必然存在的真 Mach-O 二进制（macOS runner 自带）
let fixtureBinary = "/bin/ls"
let otherBinary = "/bin/cat"
let fixtureOK = FileManager.default.fileExists(atPath: fixtureBinary)
expect(fixtureOK, "fixture binary exists: \(fixtureBinary)")

// MARK: - armor hardening

section("armor hardening（\(fixtureBinary)）")
if fixtureOK {
    let armor = BinaryArmorTool()
    var hard: [String: Any] = [:]
    do {
        hard = try armor.invoke(["command": "hardening", "path": fixtureBinary] as [String: Any])
        expect(boolOf(hard["ok"]) == true, "hardening ok:true")
    } catch {
        expect(false, "hardening 抛错: \(error)")
    }

    if let flags = dictOf(hard["flags"]) {
        expect(boolOf(flags["pie"]) == true, "flags.pie == true（系统二进制必带 MH_PIE）")
        expect(flags["no_undefs"] != nil, "flags.no_undefs 存在")
        expect(flags["two_level_namespace"] != nil, "flags.two_level_namespace 存在")
    } else {
        expect(false, "flags 是字典")
    }

    expect(intOf(hard["cryptid"]) == 0, "cryptid == 0（macOS 系统二进制不加密）")
    expect(boolOf(hard["encrypted"]) == false, "encrypted == false")
    expect(boolOf(hard["signed"]) == true, "signed == true（必有 LC_CODE_SIGNATURE）")

    let segs = arrayOf(hard["segments"]) ?? []
    expect(segs.count >= 3, "segments >= 3（实际 \(segs.count)）")
    if let first = segs.first as? [String: Any] {
        expect(strOf(first["name"]) != nil, "segment 行有 name")
        let prot = strOf(first["initprot"]) ?? ""
        expect(prot.count == 3, "segment initprot 是 rwx 三字符（'\(prot)'）")
    }
    expect(arrayOf(hard["writable_executable_segments"]) != nil, "writable_executable_segments 是数组")

    if let linked = dictOf(hard["linked"]) {
        expect(boolOf(linked["libSystem"]) == true, "linked.libSystem == true")
    } else {
        expect(false, "linked 是字典")
    }

    if let score = intOf(hard["score"]) {
        expect(score >= 0 && score <= 100, "score 在 0...100（\(score)）")
    } else {
        expect(false, "score 是整数")
    }
    expect(arrayOf(hard["findings"]) != nil, "findings 是数组")
    expect((strOf(hard["evidence"]) ?? "").contains("segs="), "evidence 含 segs= 计数字段")
    expect(arrayOf(hard["limitations"]) != nil, "limitations 已给出")

    // 同一个工具对自己的可执行文件也要能跑（swiftc 产物也是 Mach-O）
    let selfPath = CommandLine.arguments[0]
    do {
        let selfOut = try armor.invoke(["command": "hardening", "path": selfPath] as [String: Any])
        expect(boolOf(selfOut["ok"]) == true, "hardening 自身二进制 ok:true")
    } catch {
        expect(false, "hardening 自身二进制抛错: \(error)")
    }
}

// 非 Mach-O 必须结构化报错，不能崩
section("armor hardening 拒绝非 Mach-O")
do {
    let txt = tmpRoot + "/not-a-binary.txt"
    try "hello".write(toFile: txt, atomically: true, encoding: .utf8)
    _ = try BinaryArmorTool().invoke(["command": "hardening", "path": txt] as [String: Any])
    expect(false, "文本文件应抛 MCPError.invalidParams")
} catch let e as MCPError {
    expect("\(e)".contains("invalid params"), "文本文件抛 invalidParams（'\(e)'）")
} catch {
    expect(false, "抛了非 MCPError: \(error)")
}

// MARK: - armor toolchain

section("armor toolchain（\(fixtureBinary)）")
if fixtureOK {
    do {
        let out = try BinaryArmorTool().invoke(["command": "toolchain", "path": fixtureBinary] as [String: Any])
        expect(boolOf(out["ok"]) == true, "toolchain ok:true")
        expect(out["go"] == nil, "go == nil（系统二进制不是 Go 构建）")
        expect(out["rust"] == nil, "rust == nil")
        expect(arrayOf(out["language_hints"]) != nil, "language_hints 是数组")
        expect(strOf(out["note"])?.contains("Go buildinfo") == true, "未命中时给出 note 说明")
        expect(strOf(out["evidence"])?.contains("go=") == true, "evidence 含 go=/rust= 判定")
    } catch {
        expect(false, "toolchain 抛错: \(error)")
    }
}

// MARK: - armor diff

section("armor diff（\(fixtureBinary) vs \(otherBinary)）")
if fixtureOK {
    do {
        let out = try BinaryArmorTool().invoke([
            "command": "diff", "path": fixtureBinary, "path2": otherBinary, "limit": 20,
        ] as [String: Any])
        expect(boolOf(out["ok"]) == true, "diff ok:true")
        expect(intOf(out["added_count"]) != nil, "added_count 是整数")
        expect(intOf(out["removed_count"]) != nil, "removed_count 是整数")
        expect(arrayOf(out["added"]) != nil, "added 是数组（分页后）")
        expect(arrayOf(out["segments"]) != nil, "segments 增量表存在")
        if let sizes = dictOf(out["sizes"]) {
            expect((intOf(sizes["a"]) ?? 0) > 0 && (intOf(sizes["b"]) ?? 0) > 0, "sizes.a/b 都是正数")
            expect(intOf(sizes["delta"]) != nil, "sizes.delta 存在")
        } else {
            expect(false, "sizes 是字典")
        }
        expect(strOf(out["evidence"])?.contains("armor diff symbols") == true, "evidence 说明比较口径")
    } catch {
        expect(false, "diff 抛错: \(error)")
    }

    // 同类校验收紧：二进制 vs 目录要拒绝
    do {
        _ = try BinaryArmorTool().invoke([
            "command": "diff", "path": fixtureBinary, "path2": tmpRoot,
        ] as [String: Any])
        expect(false, "二进制 vs 目录 应抛错")
    } catch {
        expect(true, "二进制 vs 目录 被拒绝")
    }
}

// MARK: - crash.ips parse

section("crash.ips parse（合成 .ips 夹具）")
let ipsPath = tmpRoot + "/SelfTest-2024-01-01-000000.ips"
let ipsHeader = #"{"app_name":"SelfTest","bug_type":"309","os_version":"iPhone OS 17.0 (21A329)","timestamp":"2024-01-01 00:00:00.00 +0800","incident_id":"SELFTEST-INCIDENT-1"}"#
let ipsBody = #"""
{
  "procName": "SelfTest",
  "pid": 4242,
  "procPath": "/var/containers/Bundle/Application/AAA/SelfTest.app/SelfTest",
  "captureTime": "2024-01-01 00:00:00.00 +0800",
  "exception": {"type": "EXC_BAD_ACCESS", "subtype": "KERN_INVALID_ADDRESS", "codes": "0x0000000000000000, 0x0000000000000000"},
  "termination": {"namespace": "SIGNAL", "code": 11, "indicator": "Segmentation fault: 11", "reasons": ["Namespace SIGNAL, Code 11"]},
  "faultingThread": 0,
  "threads": [
    {"id": 111, "queue": "com.apple.main-thread", "frames": [
      {"imageIndex": 0, "imageOffset": 4096, "symbol": "-[ViewController viewDidLoad]", "symbolLocation": 42},
      {"imageIndex": 0, "imageOffset": 8192, "symbol": "main", "symbolLocation": 8}
    ]},
    {"id": 222, "frames": [
      {"imageIndex": 0, "imageOffset": 12288}
    ]}
  ],
  "usedImages": [
    {"name": "SelfTest", "path": "/var/containers/Bundle/Application/AAA/SelfTest.app/SelfTest", "base": 4294967296, "size": 1048576, "uuid": "00000000-1111-2222-3333-444444444444", "arch": "arm64"}
  ],
  "lastExceptionBacktrace": [
    {"imageIndex": 0, "imageOffset": 4096, "symbol": "-[ViewController viewDidLoad]", "symbolLocation": 42}
  ],
  "asi": {"libsystem_c.dylib": ["SelfTest(4242,0x16f0ab000) malloc: *** error for object"]}
}
"""#
try? (ipsHeader + "\n" + ipsBody).write(toFile: ipsPath, atomically: true, encoding: .utf8)

do {
    let out = try CrashIPSTool().invoke(["command": "parse", "path": ipsPath] as [String: Any])
    expect(boolOf(out["ok"]) == true, "parse ok:true")
    expect(strOf(out["format"]) == "ips-json", "format == ips-json（实际 '\(strOf(out["format"]) ?? "nil")'）")

    if let header = dictOf(out["header"]) {
        expect(strOf(header["app_name"]) == "SelfTest", "header.app_name 读到了")
        expect(strOf(header["bug_type"]) == "309", "header.bug_type 读到了")
        expect(strOf(header["incident_id"]) == "SELFTEST-INCIDENT-1", "header.incident_id 读到了")
    } else {
        expect(false, "header 是字典")
    }

    if let proc = dictOf(out["process"]) {
        expect(strOf(proc["procName"]) == "SelfTest", "process.procName 读到了")
        expect(intOf(proc["pid"]) == 4242, "process.pid == 4242")
    } else {
        expect(false, "process 是字典")
    }

    if let exc = dictOf(out["exception"]) {
        expect(strOf(exc["type"]) == "EXC_BAD_ACCESS", "exception.type 读到了")
        expect(strOf(exc["subtype"]) == "KERN_INVALID_ADDRESS", "exception.subtype 读到了")
    } else {
        expect(false, "exception 是字典")
    }

    if let term = dictOf(out["termination"]) {
        expect(strOf(term["namespace"]) == "SIGNAL", "termination.namespace 读到了")
        expect(intOf(term["code"]) == 11, "termination.code == 11")
        expect((arrayOf(term["reasons"]) ?? []).count == 1, "termination.reasons 透传")
    } else {
        expect(false, "termination 是字典")
    }

    expect(intOf(out["faulting_thread"]) == 0, "faulting_thread == 0")
    expect(intOf(out["threads_total"]) == 2, "threads_total == 2")
    expect(intOf(out["images_total"]) == 1, "images_total == 1")

    let frames = arrayOf(out["faulting_frames"]) ?? []
    expect(frames.count == 2, "faulting_frames == 2（实际 \(frames.count)）")
    if let f0 = frames.first as? [String: Any] {
        expect(strOf(f0["image"]) == "SelfTest", "帧 image 由 imageIndex 反查得到")
        expect(strOf(f0["offset"]) == "0x1000", "帧 offset == 0x1000（实际 '\(strOf(f0["offset"]) ?? "nil")'）")
        expect(strOf(f0["address"]) == "0x100001000", "帧 address == base+offset（实际 '\(strOf(f0["address"]) ?? "nil")'）")
        expect(strOf(f0["symbol"]) == "-[ViewController viewDidLoad]", "帧 symbol 透传")
        expect(intOf(f0["symbol_location"]) == 42, "帧 symbol_location == 42")
    } else {
        expect(false, "第一帧是字典")
    }

    expect((arrayOf(out["last_exception_backtrace"]) ?? []).count == 1, "lastExceptionBacktrace 解析到")
    expect(dictOf(out["asi"]) != nil, "asi 透传")
    expect((arrayOf(out["evidence"]) ?? []).count >= 3, "evidence 至少 3 行")
    expect((arrayOf(out["limitations"]) ?? []).count >= 3, "limitations 至少 3 条")
} catch {
    expect(false, "crash.ips parse 抛错: \(error)")
}

// 二进制垃圾必须结构化报错
do {
    let bad = tmpRoot + "/garbage.ips"
    _ = FileManager.default.createFile(atPath: bad, contents: Data([0xff, 0xfe, 0x00, 0x01, 0x02]))
    _ = try CrashIPSTool().invoke(["command": "parse", "path": bad] as [String: Any])
    expect(false, "非 UTF-8 报告应抛错，却返回了结果")
} catch {
    expect(true, "非 UTF-8 报告被拒绝（\(type(of: error))）")
}

// MARK: - BundleAnatomy（package inspect <dir> 的实现）
// 注释：`#"..."#` 见上；此处路径分开写，避开插值

section("BundleAnatomy.inspect（合成 .app 目录）")
let appDir = tmpRoot + "/SelfTest.app"
let fm = FileManager.default
try? fm.createDirectory(atPath: appDir, withIntermediateDirectories: true)
try? fm.createDirectory(atPath: appDir + "/Frameworks/Dummy.framework", withIntermediateDirectories: true)
try? fm.createDirectory(atPath: appDir + "/PlugIns", withIntermediateDirectories: true)
try? Data([0x00, 0x01, 0x02]).write(to: URL(fileURLWithPath: appDir + "/Assets.car"))

if fixtureOK {
    try? fm.copyItem(atPath: fixtureBinary, toPath: appDir + "/SelfTest")
}

let info: [String: Any] = [
    "CFBundleIdentifier": "com.example.parseselftest",
    "CFBundleName": "SelfTest",
    "CFBundleDisplayName": "Self Test",
    "CFBundleExecutable": "SelfTest",
    "CFBundleShortVersionString": "1.2.3",
    "CFBundleVersion": "45",
    "CFBundlePackageType": "APPL",
    "MinimumOSVersion": "15.0",
    "DTSDKName": "iphoneos17.0",
    "DTPlatformName": "iphoneos",
    "UIDeviceFamily": [1, 2],
    "NSCameraUsageDescription": "自检用",
    "NSPhotoLibraryUsageDescription": "自检用",
    "CFBundleURLTypes": [["CFBundleURLSchemes": ["selftest"]]],
    "UIBackgroundModes": ["audio"],
]
if let plist = try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0) {
    try? plist.write(to: URL(fileURLWithPath: appDir + "/Info.plist"))
    expect(true, "写出 Info.plist")
} else {
    expect(false, "Info.plist 序列化失败")
}

do {
    let out = try BundleAnatomy.inspect(appDir)
    expect(strOf(out["format"]) == "app-bundle", "format == app-bundle")

    if let bundle = dictOf(out["bundle"]) {
        expect(strOf(bundle["identifier"]) == "com.example.parseselftest", "bundle.identifier 读到了")
        expect(strOf(bundle["version"]) == "1.2.3", "bundle.version == 1.2.3")
        expect(strOf(bundle["build"]) == "45", "bundle.build == 45")
        expect(strOf(bundle["executable"]) == "SelfTest", "bundle.executable 读到了")
        expect((arrayOf(bundle["privacy_usage_keys"]) ?? []).count == 2, "privacy_usage_keys == 2")
        expect((arrayOf(bundle["url_schemes"]) ?? []).contains { ($0 as? String) == "selftest" }, "url_schemes 含 selftest")
        expect((arrayOf(bundle["background_modes"]) ?? []).contains { ($0 as? String) == "audio" }, "background_modes 含 audio")
        expect((intOf(bundle["info_plist_bytes"]) ?? 0) > 0, "info_plist_bytes > 0")
    } else {
        expect(false, "bundle 是字典")
    }

    if let binary = dictOf(out["binary"]) {
        expect(strOf(binary["path"])?.hasSuffix("/SelfTest") == true, "binary.path 指向 Info.plist 声明的可执行文件")
        expect((intOf(binary["size"]) ?? 0) > 0, "binary.size > 0")
        expect(boolOf(binary["has_code_signature"]) == true, "主二进制 has_code_signature == true")
        expect(intOf(binary["linked_dylibs_total"]) != nil, "linked_dylibs_total 是整数")
        expect(strOf(binary["uuid"]) != nil, "主二进制 uuid 读到了")
    } else {
        expect(false, "binary 是字典")
    }

    expect(intOf(out["frameworks_total"]) == 1, "frameworks_total == 1")
    expect(intOf(out["plugins_total"]) == 0, "plugins_total == 0")
    expect((intOf(out["top_level_total"]) ?? 0) >= 3, "top_level_total >= 3")
    if let res = dictOf(out["resources"]) {
        expect(intOf(res["assets_car_bytes"]) == 3, "resources.assets_car_bytes == 3")
    } else {
        expect(false, "resources 是字典")
    }
} catch {
    expect(false, "BundleAnatomy.inspect 抛错: \(error)")
}

// 没有 Info.plist 的目录必须给出结构化诊断
do {
    let noInfo = tmpRoot + "/NoInfo.app"
    try? fm.createDirectory(atPath: noInfo, withIntermediateDirectories: true)
    _ = try BundleAnatomy.inspect(noInfo)
    expect(false, "缺 Info.plist 应抛错")
} catch let e as MCPError {
    expect("\(e)".contains("BAD_FORMAT"), "缺 Info.plist 抛 BAD_FORMAT（'\(e)'）")
} catch {
    expect(false, "抛了非 MCPError: \(error)")
}

// MARK: - 汇总

print("\n=== 解析层自检结果：\(passes) passed, \(failures) failed ===")
if failures > 0 {
    print("FAILED")
    exit(1)
}
print("ALL GREEN")
exit(0)
