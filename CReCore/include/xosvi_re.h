// xosvi_re.h — Xosvi 内置逆向解析引擎（Mach-O / ObjC 元数据 / 字符串与交叉引用）
//
// 为什么用 C 而不是 Swift：解析器要逐字节读 Mach-O，C 版本能在真机上用 clang
// 直接编译验证（本机无 swiftc），Swift 侧只做路径解析与结果汇总。
//
// 输出：每个输入文件写 <out_dir>/report.json 与 <out_dir>/report.md。
// 只做只读解析，不修改输入文件。

#ifndef XOSVI_RE_H
#define XOSVI_RE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// 返回引擎版本，形如 "1.0.0"。
const char *xosvi_re_version(void);

// 完整分析一个 Mach-O（thin 或 fat，dylib / framework 二进制 / 可执行文件）。
//
// file_path  输入文件的绝对路径
// out_dir    输出目录（必须已存在），写 report.json + report.md
// options    可传 NULL；分号分隔的键值，支持：
//              max_strings=N   最多收集多少条字符串（默认 20000）
//              min_len=N       字符串最短长度（默认 4）
//              xrefs=1   默认开启字符串交叉引用扫描；0 关闭（大文件更快）
// err / err_cap  失败时写入错误文案
//
// 返回 0 成功；非 0 失败。
int xosvi_re_analyze(const char *file_path, const char *out_dir, const char *options,
                     char *err, size_t err_cap);

// 只抽取字符串（可按子串过滤），写 <out_dir>/strings.json，不写报告。
// query 为 NULL 或空串时返回全部字符串。
int xosvi_re_strings(const char *file_path, const char *query, const char *out_dir,
                     char *err, size_t err_cap);

#ifdef __cplusplus
}
#endif

#endif
