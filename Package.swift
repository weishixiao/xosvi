// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Xosvi",
    // v2.9.250: 部署目标 16→15 治本——按16编译会引用 iOS16+ 符号(URLRequest.httpMethod/timeoutInterval 等 availability 标注错误的 Swift setter),iOS15.6 dyld 启动崩;15 避开 iOS16+ API 且保留全部 iOS15 API(safeAreaInset 等),降14过度会报 iOS15 API 编译错误
    // v6.8.1：补声明 macOS——SwiftPM 在解析依赖时会对所有平台做兼容性检查。
    // 只写 .iOS 时 macOS 按默认 10.13 处理，而 MachOKit 要求 10.15+，
    // 构建直接报 "requires macos 10.13, but depends on product 'MachOKit' which requires macos 10.15"。
    // 这里是 macOS 构建时的下限，不影响 iOS 产物。
    platforms: [.iOS(.v15), .macOS(.v10_15)],
    dependencies: [
        // v2.9.370：RSKGrowingTextView——成熟开源聊天输入框，自动高度+占位符，替代手写 UIViewRepresentable
        .package(url: "https://github.com/ruslanskorb/RSKGrowingTextView.git", from: "7.0.0"),
        // v3.0.37：ZIPFoundation——iSH rootfs 首次启动解压（OpenMinis 同款）
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        // v6.8.0：MachOKit——Mach-O 静态解析（MIT，上游声明 iOS 13+）。
        // 供 macho 工具读取头信息 / entitlements / codesign / 导出符号。
        // 注意：它要求 swift-tools-version 5.10，CI 的 macos-latest（Swift 6.x）满足。
        .package(url: "https://github.com/p-x9/MachOKit.git", from: "0.55.0")
    ],
    targets: [
        // v7.6.0：iSH 沙盒桥接层（移植自 Kelivo 的 ios/Runner/Workspace/KelivoISH*）
        // 产物由 Sandbox/build_ish.sh 生成到 Sandbox/build/{include,iphoneos}，
        // 构建设置与 Kelivo 的 Xcode 配置保持一致（ISH_INTERNAL / GUEST_ARM64）。
        .target(
            name: "ISHBridge",
            path: "Sources/ISHBridge",
            publicHeadersPath: ".",
            cSettings: [
                .headerSearchPath("../../Sandbox/build/include"),
                .headerSearchPath("../../Sandbox/build/include/ish"),
                .define("ISH_INTERNAL", to: "1"),
                .define("GUEST_ARM64", to: "1")
            ],
            linkerSettings: [
                // -ObjC 必须经 -Xlinker 传给链接器，直接写会被 swiftc 当成编译参数
                // （CI 报 error: unknown argument: '-ObjC'）
                .unsafeFlags(["-L", "Sandbox/build/iphoneos", "-Xlinker", "-ObjC"]),
                .linkedLibrary("ish"),
                .linkedLibrary("ish_emu"),
                .linkedLibrary("fakefs"),
                .linkedLibrary("sqlite3")
            ]
        ),
        // v3.3.0：MITM 内核 C 桥接层（OpenSSL）。依赖 scripts/build-openssl.sh 产出的 openssl-stage/
        .target(
            name: "CMitm",
            path: "CMitm",
            cSettings: [
                .headerSearchPath("../openssl-stage/include")
            ],
            linkerSettings: [
                .unsafeFlags(["-L", "openssl-stage/lib"]),
                .linkedLibrary("ssl"),
                .linkedLibrary("crypto")
            ]
        ),
        // v3.3.0：MITM 代理内核（主 App 本地代理模式 + VpnTunnel appex 共用）
        .target(
            name: "MitmCore",
            dependencies: ["CMitm"],
            path: "Sources/MitmCore"
        ),
        // v6.0.4：桌面悬浮 HUD 提权 spawn C 层。persona 99 提权放 C（posix_spawnattr_t 在 C 是 void*，
        // 无 Swift 类型混乱）。Swift 主 App import CLaunch 调 troll_launch_hud()。
        .target(
            name: "CLaunch",
            path: "CLaunch",
            publicHeadersPath: "."
        ),
        // v6.7.0：VansonEngine——VansonMod 内存引擎（GPL-3.0）桥接层。
        // 把 VansonEngine/ 下的 ObjC++/C++ 内存扫描引擎编成 libVansonEngine.a（scripts/build-vanson.sh），
        // SwiftPM 这边只负责导出 ObjC 头 + 链接静态库；主 App import VansonEngine 即可用
        // VMMemoryEngine（搜索/读写/冻结/指针链）。
        .target(
            name: "VansonEngine",
            path: "VansonEngine",
            exclude: ["src", "README.md"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath(".")
            ],
            linkerSettings: [
                .unsafeFlags(["-L", "vanson-stage/lib"]),
                .linkedLibrary("VansonEngine"),
                .linkedLibrary("c++")
            ]
        ),
        // fix3cy16 (P1)：CHev——hev-socks5-tunnel 桥接层（iOS 真机 slice 手动链接，
        //   避开 SwiftPM binaryTarget 平台选择问题）。依赖 scripts/build-ipa.sh 下载解压的
        //   hev-stage/lib/libhev-socks5-tunnel.a（ios-arm64 slice，Tun2SocksKit 5.16.0 release）
        .target(
            name: "CHev",
            path: "CHev",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags(["-L", "hev-stage/lib"]),
                .linkedLibrary("hev-socks5-tunnel")
            ]
        ),
        // v6.6.8：CLZMA——进程内 LZMA1 解码器（公有领域 LZMA SDK 的 LzmaDec）。
        // 为什么必须内置：Apple Compression 的 COMPRESSION_LZMA 只吃「XZ 容器里的 LZMA2」，
        // deb 的 data.tar.lzma 是 .lzma-alone，compression_decode_buffer 恒返回 0；
        // 而 App 内拉起 python3/bsdtar 子进程在部分越狱环境会被 AMFI 拒（Bad executable），
        // 导致 package unpack 永远失败。C 解码器不依赖任何子进程与系统框架。
        .target(
            name: "CLZMA",
            path: "CLZMA",
            // 只公开 lzma_shim.h：7zTypes.h 里有 `typedef int Bool`，
            // 一旦进公共头就会污染 Swift 侧（Bool 变成 Int32，整个文件编译失败）。
            publicHeadersPath: "include",
            cSettings: [
                // xz-embedded 的头文件在 CLZMA/xz/ 下，供 xz_shim.c 解析
                .headerSearchPath("xz"),
                .define("XZ_USE_CRC64")
            ]
        ),
        // v6.6.16：CPyEmbed——进程内 CPython（dlopen Python.framework）。
        // 越狱对 posix_spawn 返回 ENOSYS，bin/python3 起不来；
        // 这个目标不链接 Python、不需要 Python 头文件，运行时 dlopen + dlsym。
        .target(
            name: "CPyEmbed",
            path: "CPyEmbed",
            publicHeadersPath: "public"
        ),
        // v10.x：CReCore——内置逆向解析引擎（纯 C，无第三方依赖）。
        // 越狱环境下 r2/objcdump 之类外部工具起不来，而解析 Mach-O 只要逐字节读文件，
        // 放进主进程后「解包 → 出报告」不再依赖任何子进程。
        .target(
            name: "CReCore",
            path: "CReCore",
            publicHeadersPath: "include"
        ),
        // v6.6.15：CCapstone——进程内反汇编（capstone 5.0.3，BSD-3）。
        // 越狱会拒绝执行 App 内的第三方二进制（posix_spawn → ENOSYS 85），
        // r2/cstool 起不来；把 capstone 静态库链进主二进制后反汇编不再依赖子进程。
        // 静态库来自 CI 的 native-tools 产物（native-tools-out/libcapstone.a）。
        .target(
            name: "CCapstone",
            path: "CCapstone",
            publicHeadersPath: "public",
            cSettings: [
                .headerSearchPath("vendor")
            ],
            linkerSettings: [
                .unsafeFlags(["-L", "native-tools-out"]),
                .linkedLibrary("capstone")
            ]
        ),
        // v3.3.0：VPN 抓包模式 appex（PacketTunnelProvider，P1 hev 转发内核）
        .executableTarget(
            name: "VpnTunnel",
            dependencies: ["MitmCore", "CMitm", "CHev"],
            path: "Sources/VpnTunnel",
            linkerSettings: [
                .linkedFramework("NetworkExtension")
            ]
        ),
        .executableTarget(
            name: "Xosvi",
            dependencies: [
                .product(name: "RSKGrowingTextView", package: "RSKGrowingTextView"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                // v6.8.0：Mach-O 静态解析（macho 工具的后端）
                .product(name: "MachOKit", package: "MachOKit"),
                "ISHBridge",
                "MitmCore",
                "CMitm",
                "CLaunch",
                "CLZMA",
                "CCapstone",
                "CPyEmbed",
                // v10.x：内置逆向引擎（re 工具后端）
                "CReCore",
                // v6.7.0：VansonMod 内存引擎（GPL-3.0）——memory 工具的原生扫描/读写/冻结实现
                "VansonEngine"
            ],
            path: "Sources/XosviMCP",
            exclude: ["Resources"],
            linkerSettings: [
                .linkedLibrary("z"),
                // v6.6.22：db 工具进程内读库（不依赖 Alpine 的 sqlite3）
                .linkedLibrary("sqlite3"),
                .linkedFramework("NetworkExtension"),
                // v6.9.14：可爱助手 / 桌面悬浮 HUD 已删除，不再链接 libHUD.a 与私有 framework tbd。
            ]
        ),
        // v9：纯数据层单测（MessagePart / 迁移 / 投影器 / 工具结果回填）
        // 注意：主 target 是 iOS App（依赖 UIKit / NetworkExtension），本测试目标只在
        // 具备 iOS SDK 的环境下可跑；CI 的 swiftc -parse 门禁不覆盖 tests/。
        .testTarget(
            name: "XosviTests",
            dependencies: ["Xosvi"],
            path: "tests/UnitTests"
        ),
    ]
)
