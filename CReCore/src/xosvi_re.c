// xosvi_re.c — Xosvi 内置逆向解析引擎
//
// 一个文件读下来做完：Mach-O 装载命令 → chained fixups / dyld bind 解压 →
// ObjC 类/分类/协议/方法/ivar/属性回读 → 字符串收集 → 函数起点与 objc stub
// 还原 → adrp/add 交叉引用 → report.json + report.md。
//
// 设计约束：
//   * 不依赖任何第三方库、不 spawn 子进程（App 内 posix_spawn 在越狱上会被拒）。
//   * 所有指针读取都先做边界检查；坏数据只降级为“解不出”，绝不越界。
//   * 一次调用内用 arena 分配，退出时统一释放（长驻 App 进程不泄漏）。
//
// 单独编译验证：
//   clang -O1 -Wall -DXRE_TOOL -o xre CReCore/src/xosvi_re.c && ldid -S xre
//   ./xre <macho> <outdir> [options]

#include "xosvi_re.h"

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef int32_t i32;
typedef int64_t i64;

#define XRE_VERSION "1.0.0"
#define MAX_SECTIONS 2048
#define MAX_SEGMENTS 64
#define MAX_FIXUPS 400000
#define MAX_CLASSES 6000
#define MAX_CATEGORIES 4000
#define MAX_PROTOCOLS 3000
#define MAX_METHODS 4000
#define MAX_IVARS 600
#define MAX_PROPS 1200
#define MAX_STRINGS 40000
#define MAX_REFS_PER_STRING 6
#define MAX_XREFS 200000
#define MAX_FUNCS 200000
#define MAX_STUBS 8000
#define MAX_LINKED 256
#define MAX_CALLS 600000

// ---------------------------------------------------------------- 基础读取

static u8 *B;              // 当前切片（fat 时指向选中 slice）
static size_t N;           // 当前切片长度
static u64 g_image_base;   // 映象基址（__TEXT.vmaddr - fileoff）

static u16 le16(size_t o) {
    if (o + 2 > N) return 0;
    return (u16)((u32)B[o] | ((u32)B[o + 1] << 8));
}
static u32 le32(size_t o) {
    if (o + 4 > N) return 0;
    return (u32)B[o] | ((u32)B[o + 1] << 8) | ((u32)B[o + 2] << 16) | ((u32)B[o + 3] << 24);
}
static u64 le64(size_t o) {
    if (o + 8 > N) return 0;
    u64 v = 0;
    for (int i = 7; i >= 0; i--) v = (v << 8) | B[o + (size_t)i];
    return v;
}

// ---------------------------------------------------------------- arena

typedef struct AChunk {
    struct AChunk *next;
    size_t used, cap;
    char data[1];
} AChunk;

static AChunk *g_arena;

static void *ax(size_t n) {
    n = (n + 15u) & ~(size_t)15u;
    if (!g_arena || g_arena->used + n > g_arena->cap) {
        size_t cap = n > 262144 ? n : 262144;
        AChunk *c = (AChunk *)calloc(1, sizeof(AChunk) + cap);
        if (!c) return NULL;
        c->cap = cap;
        c->next = g_arena;
        g_arena = c;
    }
    void *p = g_arena->data + g_arena->used;
    g_arena->used += n;
    return p;
}
static char *adupn(const char *s, size_t n) {
    if (!s) return NULL;
    char *p = (char *)ax(n + 1);
    if (!p) return NULL;
    memcpy(p, s, n);
    p[n] = 0;
    return p;
}
static char *adup(const char *s) { return s ? adupn(s, strlen(s)) : NULL; }
static char *afmt(const char *fmt, ...) {
    char tmp[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(tmp, sizeof(tmp), fmt, ap);
    va_end(ap);
    return adup(tmp);
}
static void arena_reset(void) {
    AChunk *c = g_arena;
    while (c) {
        AChunk *n = c->next;
        free(c);
        c = n;
    }
    g_arena = NULL;
}

// ---------------------------------------------------------------- 字符串缓冲

typedef struct {
    char *p;
    size_t n, cap;
} SB;

static void sb_init(SB *b) {
    b->cap = 65536;
    b->p = (char *)malloc(b->cap);
    b->n = 0;
    if (b->p) b->p[0] = 0;
}
static void sb_need(SB *b, size_t extra) {
    if (!b->p) return;
    if (b->n + extra + 1 <= b->cap) return;
    size_t cap = b->cap * 2;
    while (cap < b->n + extra + 1) cap *= 2;
    char *np = (char *)realloc(b->p, cap);
    if (!np) return;
    b->p = np;
    b->cap = cap;
}
static void sb_add(SB *b, const char *s, size_t n) {
    if (!b->p || !s) return;
    sb_need(b, n);
    if (b->n + n + 1 > b->cap) return;
    memcpy(b->p + b->n, s, n);
    b->n += n;
    b->p[b->n] = 0;
}
static void sb_puts(SB *b, const char *s) {
    if (s) sb_add(b, s, strlen(s));
}
static void sb_printf(SB *b, const char *fmt, ...) {
    char tmp[2048];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(tmp, sizeof(tmp), fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if ((size_t)n >= sizeof(tmp)) n = (int)sizeof(tmp) - 1;
    sb_add(b, tmp, (size_t)n);
}
// JSON 字符串（含引号），控制字符转 \u00XX，非 ASCII 原样保留（合法 UTF-8）
static void sb_jstr(SB *b, const char *s) {
    sb_add(b, "\"", 1);
    if (s) {
        for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
            unsigned char c = *p;
            switch (c) {
                case '"': sb_add(b, "\\\"", 2); break;
                case '\\': sb_add(b, "\\\\", 2); break;
                case '\n': sb_add(b, "\\n", 2); break;
                case '\r': sb_add(b, "\\r", 2); break;
                case '\t': sb_add(b, "\\t", 2); break;
                default:
                    if (c < 0x20) {
                        char t[8];
                        snprintf(t, sizeof(t), "\\u%04x", c);
                        sb_add(b, t, 6);
                    } else {
                        sb_add(b, (const char *)p, 1);
                    }
            }
        }
    }
    sb_add(b, "\"", 1);
}
// Markdown 表格单元转义
static char *md_cell(const char *s) {
    if (!s) return adup("-");
    size_t n = strlen(s);
    char *o = (char *)ax(n * 2 + 2);
    if (!o) return adup("-");
    size_t k = 0;
    for (size_t i = 0; i < n; i++) {
        char c = s[i];
        if (c == '|') {
            o[k++] = '\\';
            o[k++] = '|';
        } else if (c == '\n' || c == '\r') {
            o[k++] = ' ';
        } else if (c == '`') {
            o[k++] = '\'';
        } else {
            o[k++] = c;
        }
    }
    o[k] = 0;
    return o;
}

// ---------------------------------------------------------------- 段与节

typedef struct {
    char seg[17], sect[17];
    u64 addr, size;
    u32 off, flags;
} Sect;
static Sect *g_sects;
static int g_nsects;

typedef struct {
    char name[17];
    u64 vmaddr, vmsize, fileoff, filesize;
} Seg;
static Seg *g_segs;
static int g_nsegs;

static long v2o(u64 va) {
    for (int i = 0; i < g_nsects; i++) {
        const Sect *s = &g_sects[i];
        if (s->size == 0 || s->off == 0) continue;
        if (va >= s->addr && va < s->addr + s->size) {
            u64 d = va - s->addr;
            if ((u64)s->off + d + 8 > N) return -1;
            return (long)((u64)s->off + d);
        }
    }
    return -1;
}
static const Sect *sect_by_name(const char *seg, const char *sect) {
    for (int i = 0; i < g_nsects; i++)
        if (!strcmp(g_sects[i].sect, sect) && (!seg || !strcmp(g_sects[i].seg, seg))) return &g_sects[i];
    return NULL;
}

// 读 C 字符串（va → 校验 NUL 结尾）。
static const char *cstr_at(u64 va) {
    long o = v2o(va);
    if (o < 0) return NULL;
    size_t max = N - (size_t)o;
    if (max > 1024) max = 1024;
    size_t len = 0;
    while (len < max && B[(size_t)o + len]) len++;
    if (len >= max) return NULL;
    return adupn((const char *)(B + o), len);
}
// va 处的 C 字符串是否像 selector / 标识符
static int looks_like_ident(const char *s) {
    if (!s || !*s) return 0;
    size_t n = strlen(s);
    if (n > 300) return 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c < 0x20 || c > 0x7e || c == ' ' || c == '"') return 0;
    }
    return 1;
}

// ---------------------------------------------------------------- fixups

typedef struct {
    u64 va;
    u64 target;
    const char *name;  // 仅 bind 有
    u8 bind;
} Fix;
static Fix *g_fix;
static int g_nfix;
static int g_binds, g_rebases;

static int fix_cmp(const void *a, const void *b) {
    u64 x = ((const Fix *)a)->va, y = ((const Fix *)b)->va;
    return x < y ? -1 : (x > y ? 1 : 0);
}
static int fix_find(u64 va) {
    int lo = 0, hi = g_nfix - 1;
    while (lo <= hi) {
        int mid = (lo + hi) / 2;
        if (g_fix[mid].va == va) return mid;
        if (g_fix[mid].va < va) lo = mid + 1; else hi = mid - 1;
    }
    return -1;
}
static void fix_add(u64 va, int isBind, u64 target, const char *name) {
    if (g_nfix >= MAX_FIXUPS) return;
    g_fix[g_nfix].va = va;
    g_fix[g_nfix].bind = (u8)isBind;
    g_fix[g_nfix].target = target;
    g_fix[g_nfix].name = name ? adup(name) : NULL;
    g_nfix++;
    if (isBind) g_binds++; else g_rebases++;
}
// 指针槽取值：有 fixup 用 fixup，否则按原始 8 字节
static u64 dec(u64 va) {
    int i = fix_find(va);
    if (i >= 0) return g_fix[i].bind ? 0 : g_fix[i].target;
    long o = v2o(va);
    if (o < 0) return 0;
    return le64((size_t)o);
}
static const char *dec_name(u64 va) {
    int i = fix_find(va);
    return (i >= 0 && g_fix[i].bind) ? g_fix[i].name : NULL;
}

// chained fixups 的 import 表
static u32 g_import_count, g_import_format;
static size_t g_import_base, g_symbols_base;

static const char *symbol_at(size_t off) {
    if (off >= N) return NULL;
    size_t len = 0;
    while (off + len < N && B[off + len] && len < 512) len++;
    if (len >= 512) return NULL;
    return adupn((const char *)(B + off), len);
}

// 有符号数读取（chained fixup 的 addend 等）
static i64 le64s(size_t o) { return (i64)le64(o); }

static const char *import_name(u32 ordinal) {
    if (ordinal >= g_import_count) return NULL;
    size_t io = g_import_base + (size_t)ordinal * (g_import_format == 1 ? 4u : 8u);
    if (io + 8 > N) return NULL;
    u32 nameOff = 0;
    if (g_import_format == 1) nameOff = (le32(io) >> 9) & 0x7FFFFF;
    else if (g_import_format == 2) nameOff = le32(io);
    else return NULL;
    if (g_symbols_base + nameOff >= N) return NULL;
    return symbol_at(g_symbols_base + nameOff);
}

// ---------------------------------------------------------------- chained fixups

// 指针格式语义（mach-o/fixup-chains.h）：
//   1 / 9 / 12  arm64e：bind 位 62，auth 位 63，next 位 51..61，stride 8
//               fmt 1 非认证 target 是 vmaddr；fmt 9/12 是 vm offset；认证 target 是 runtimeOffset
//   2           PTR_64：bind 位 63，next 位 51..62，target 36 位 = vmaddr，stride 4
//   6           PTR_64_OFFSET：同上，target 是 vm offset（要加 image base）
static int fmt_is_arm64e(u16 f) { return f == 1 || f == 9 || f == 12 || f == 10 || f == 13 || f == 14; }
static int fmt_is_ptr64(u16 f) { return f == 2 || f == 6 || f == 8; }
static u32 fmt_stride(u16 f) {
    if (f == 2 || f == 6 || f == 8) return 4;
    if (f == 7 || f == 10 || f == 14) return 4;
    return 8;
}

static void walk_chain(u64 va, u16 fmt) {
    u64 limit = N * 1 + g_image_base;  // 只用于避免无边界循环，真正的边界靠 v2o
    (void)limit;
    for (int guard = 0; guard < 200000; guard++) {
        long o = v2o(va);
        if (o < 0) return;
        u64 raw = le64((size_t)o);
        u64 next = 0, target = 0;
        int isBind = 0;
        const char *name = NULL;
        u32 ordinal = 0;
        int haveOrdinal = 0;

        if (fmt_is_ptr64(fmt)) {
            isBind = (int)((raw >> 63) & 1);
            next = (raw >> 51) & 0xFFF;
            if (isBind) {
                ordinal = (u32)(raw & 0xFFFFFF);
                haveOrdinal = 1;
            } else {
                target = raw & 0xFFFFFFFFFull;
                if (fmt == 6) target += g_image_base;  // runtimeOffset
                // fmt 2 已是 vmaddr；fmt 8 是内核缓存，不处理
            }
        } else if (fmt_is_arm64e(fmt)) {
            int auth = (int)((raw >> 63) & 1);
            isBind = (int)((raw >> 62) & 1);
            next = (raw >> 51) & 0x7FF;
            if (isBind) {
                ordinal = (u32)(raw & (fmt == 12 ? 0xFFFFFFu : 0xFFFFu));
                haveOrdinal = 1;
            } else if (auth) {
                target = (raw & 0xFFFFFFFFu) + g_image_base;  // runtimeOffset
            } else {
                target = raw & 0x7FFFFFFFFFFFull;
                if (fmt == 9 || fmt == 12 || fmt == 13) target += g_image_base;
            }
        } else {
            return;  // 32 位 / 不认识的格式：不猜
        }

        if (haveOrdinal) {
            name = import_name(ordinal);
            if (!name) name = afmt("#%u", ordinal);
        }
        fix_add(va, isBind, target, name);
        if (next == 0) return;
        va += (u64)next * (u64)fmt_stride(fmt);
    }
}

static void load_chained_fixups(u32 dataoff, u32 datasize) {
    if (!dataoff || datasize < 28 || (size_t)dataoff + 28 > N) return;
    size_t h = dataoff;
    u32 starts = le32(h + 4), imports = le32(h + 8), symbols = le32(h + 12);
    g_import_count = le32(h + 16);
    g_import_format = le32(h + 20);
    g_import_base = h + imports;
    g_symbols_base = h + symbols;
    size_t si = h + starts;
    if (si + 4 > N) return;
    u32 segCount = le32(si);
    if (segCount > 64) return;
    for (u32 i = 0; i < segCount; i++) {
        u32 info = le32(si + 4 + (size_t)i * 4);
        if (!info) continue;
        size_t p = si + info;
        if (p + 22 > N) continue;
        u16 pageSize = le16(p + 4);
        u16 fmt = le16(p + 6);
        u64 segOff = le64(p + 8);
        u16 pageCount = le16(p + 20);
        if (!pageSize) continue;
        size_t overflow = p + 22 + (size_t)pageCount * 2;
        for (u16 pg = 0; pg < pageCount; pg++) {
            u16 start = le16(p + 22 + (size_t)pg * 2);
            if (start == 0xFFFF) continue;
            u64 pageVA = segOff + (u64)pg * (u64)pageSize;
            if (!(start & 0x8000)) {
                walk_chain(pageVA + start, fmt);
                continue;
            }
            // multi-start：低位是溢出数组下标，0x8000 表示后面还有一条
            size_t idx = (size_t)(start & 0x7FFF);
            for (int g = 0; g < 8192; g++) {
                size_t op = overflow + idx * 2;
                if (op + 2 > N) break;
                u16 s2 = le16(op);
                walk_chain(pageVA + (u64)(s2 & 0x7FFF), fmt);
                if (!(s2 & 0x8000)) break;
                idx++;
            }
        }
    }
}

// 老式 LC_DYLD_INFO_ONLY 的 bind 操作码
static void uleb_skip(size_t *p, size_t end) {
    while (*p < end) {
        u8 c = B[(*p)++];
        if (!(c & 0x80)) break;
    }
}
static u64 uleb_read(size_t *p, size_t end) {
    u64 v = 0;
    int sh = 0;
    while (*p < end) {
        u8 c = B[(*p)++];
        v |= (u64)(c & 0x7f) << sh;
        sh += 7;
        if (!(c & 0x80)) break;
    }
    return v;
}
static void load_dyld_bind(u32 off, u32 size) {
    if (!off || !size) return;
    size_t p = off, end = (size_t)off + (size_t)size;
    if (end > N) end = N;
    u64 addr = 0;
    int segIdx = -1;
    char sym[256];
    sym[0] = 0;
    while (p < end) {
        u8 b = B[p++];
        u8 op = (u8)(b & 0xF0), imm = (u8)(b & 0x0F);
        if (op == 0x00) break;
        if (op == 0x10 || op == 0x30 || op == 0x50) continue;  // set dylib ordinal / type / add addr 无 addr
        if (op == 0x20 || op == 0x60) { uleb_skip(&p, end); continue; }  // seg offset / uleb
        if (op == 0x40) {
            size_t k = 0;
            while (p < end && B[p] && k < sizeof(sym) - 1) sym[k++] = (char)B[p++];
            sym[k] = 0;
            if (p < end) p++;
            continue;
        }
        if (op == 0x70) {
            segIdx = (int)imm;
            u64 o2 = uleb_read(&p, end);
            addr = (segIdx >= 0 && segIdx < g_nsegs ? g_segs[segIdx].vmaddr : 0) + o2;
            continue;
        }
        if (op == 0x80) {
            addr += uleb_read(&p, end);
            continue;
        }
        if (op == 0x90) { fix_add(addr, 1, 0, sym); addr += 8; continue; }
        if (op == 0xA0) { fix_add(addr, 1, 0, sym); addr += 8 + uleb_read(&p, end); continue; }
        if (op == 0xB0) { fix_add(addr, 1, 0, sym); addr += 8 + (u64)imm * 8; continue; }
        if (op == 0xC0) {
            u64 cnt = uleb_read(&p, end), skip = uleb_read(&p, end);
            for (u64 k = 0; k < cnt && k < 100000; k++) {
                fix_add(addr, 1, 0, sym);
                addr += 8 + skip;
            }
            continue;
        }
        break;
    }
}

// ---------------------------------------------------------------- 符号与函数起点

typedef struct {
    u64 va;
    const char *name;
} SymEnt;
static SymEnt *g_syms;
static int g_nsyms;

static int sym_cmp(const void *a, const void *b) {
    u64 x = ((const SymEnt *)a)->va, y = ((const SymEnt *)b)->va;
    return x < y ? -1 : (x > y ? 1 : 0);
}
static const char *sym_at(u64 va) {
    int lo = 0, hi = g_nsyms - 1;
    while (lo <= hi) {
        int mid = (lo + hi) / 2;
        if (g_syms[mid].va == va) return g_syms[mid].name;
        if (g_syms[mid].va < va) lo = mid + 1; else hi = mid - 1;
    }
    return NULL;
}

static u64 *g_fstart;
static int g_nfstart;

static void fstart_add(u64 va) {
    if (g_nfstart >= MAX_FUNCS) return;
    if (g_nfstart > 0 && va <= g_fstart[g_nfstart - 1]) return;
    g_fstart[g_nfstart++] = va;
}
// 包含该地址的函数下标（-1 表示不在任何已知函数里）
static int func_index_of(u64 va) {
    if (g_nfstart == 0) return -1;
    int lo = 0, hi = g_nfstart - 1, best = -1;
    while (lo <= hi) {
        int mid = (lo + hi) / 2;
        if (g_fstart[mid] <= va) { best = mid; lo = mid + 1; } else hi = mid - 1;
    }
    if (best < 0) return -1;
    return best;
}

// ---------------------------------------------------------------- Mach-O 装载

static u32 g_filetype, g_cputype, g_platform, g_minos;
static const char *g_arch_name = "unknown";
static const char *g_filetype_name = "unknown";
static const char *g_platform_name = "unknown";
static const char *g_linked[MAX_LINKED];
static int g_nlinked;
static u8 *g_filebuf;
static size_t g_filesize;
static u32 g_symoff, g_nsyms_raw, g_stroff;

static u32 be32(size_t o) {
    if (o + 4 > N) return 0;
    return ((u32)B[o] << 24) | ((u32)B[o + 1] << 16) | ((u32)B[o + 2] << 8) | (u32)B[o + 3];
}
static void add_linked(const char *name) {
    if (!name || g_nlinked >= MAX_LINKED) return;
    g_linked[g_nlinked++] = adup(name);
}
static const char *base_name(const char *p) {
    const char *s = p;
    for (const char *q = p; q && *q; q++)
        if (*q == '/') s = q + 1;
    return s;
}
static const char *ver_str(u32 v) {
    unsigned maj = v >> 16, min = (v >> 8) & 0xFF, pat = v & 0xFF;
    if (pat) return afmt("%u.%u.%u", maj, min, pat);
    return afmt("%u.%u", maj, min);
}
static void load_symtab(u32 symoff, u32 nsyms, u32 stroff) {
    if (!symoff || !nsyms) return;
    if ((size_t)symoff + (size_t)nsyms * 16 > N) return;
    if (nsyms > MAX_FUNCS) nsyms = MAX_FUNCS;
    g_syms = (SymEnt *)ax(sizeof(SymEnt) * nsyms);
    if (!g_syms) return;
    for (u32 i = 0; i < nsyms; i++) {
        size_t e = (size_t)symoff + (size_t)i * 16;
        u32 strx = le32(e);
        u8 type = B[e + 4];
        u64 val = le64(e + 8);
        if (!val || !strx) continue;
        if ((type & 0x0E) != 0x0E) continue;  // 只收 N_SECT 定义的符号
        size_t so = (size_t)stroff + strx;
        if (so >= N) continue;
        const char *nm = symbol_at(so);
        if (!nm || !*nm) continue;
        g_syms[g_nsyms].va = val;
        g_syms[g_nsyms].name = nm;
        g_nsyms++;
    }
    if (g_nsyms > 1) qsort(g_syms, (size_t)g_nsyms, sizeof(SymEnt), sym_cmp);
}
static void load_function_starts(u32 dataoff, u32 datasize) {
    if (!dataoff || !datasize) return;
    size_t p = dataoff, end = (size_t)dataoff + datasize;
    if (end > N) end = N;
    u64 addr = g_image_base;
    while (p < end) {
        u64 d = uleb_read(&p, end);
        if (!d) break;
        addr += d;
        fstart_add(addr);
    }
}

static int add_section(const char *seg, const char *sect, u64 addr, u64 size, u32 off, u32 flags) {
    if (g_nsects >= MAX_SECTIONS) return -1;
    Sect *s = &g_sects[g_nsects];
    memset(s, 0, sizeof(*s));
    snprintf(s->seg, sizeof(s->seg), "%s", seg);
    snprintf(s->sect, sizeof(s->sect), "%s", sect);
    s->addr = addr;
    s->size = size;
    s->off = off;
    s->flags = flags;
    return g_nsects++;
}

// 解析当前切片（B/N 已指向它）
static int parse_macho(char *err, size_t err_cap) {
    if (N < 32) {
        snprintf(err, err_cap, "文件太小，不是 Mach-O");
        return -1;
    }
    u32 magic = le32(0);
    if (magic != 0xFEEDFACFu) {
        snprintf(err, err_cap, "不是 64 位 Mach-O（magic=0x%08x）", magic);
        return -1;
    }
    g_cputype = le32(4);
    u32 subtype = le32(8);
    g_filetype = le32(12);
    u32 ncmds = le32(16), sizeofcmds = le32(20);
    switch (g_cputype) {
        case 0x0100000C:
            g_arch_name = ((subtype & 0x00FFFFFFu) == 2) ? "arm64e" : "arm64";
            break;
        case 0x0000000C: g_arch_name = "arm"; break;
        case 0x01000007: g_arch_name = "x86_64"; break;
        default: g_arch_name = afmt("cpu_0x%x", g_cputype); break;
    }
    switch (g_filetype) {
        case 1: g_filetype_name = "object"; break;
        case 2: g_filetype_name = "execute"; break;
        case 4: g_filetype_name = "core"; break;
        case 6: g_filetype_name = "dylib"; break;
        case 8: g_filetype_name = "bundle"; break;
        case 10: g_filetype_name = "dSYM"; break;
        case 11: g_filetype_name = "kext"; break;
        default: g_filetype_name = afmt("type_%u", g_filetype); break;
    }
    if ((u64)32 + sizeofcmds > N) {
        snprintf(err, err_cap, "load commands 超出文件范围");
        return -1;
    }
    size_t p = 32;
    u64 text_off_vm = 0, text_fileoff = 0;
    int have_text = 0;
    u32 lc_starts_off = 0, lc_starts_size = 0;
    u32 chain_off = 0, chain_size = 0;
    u32 bind_off = 0, bind_size = 0;
    u32 symoff = 0, nsyms = 0, stroff = 0;

    for (u32 c = 0; c < ncmds; c++) {
        if (p + 8 > (size_t)32 + sizeofcmds || p + 8 > N) break;
        u32 cmd = le32(p), cmdsize = le32(p + 4);
        if (cmdsize < 8) break;
        switch (cmd) {
            case 0x19: {  // LC_SEGMENT_64
                if (cmdsize < 72) break;
                char seg[17];
                memcpy(seg, B + p + 8, 16);
                seg[16] = 0;
                u64 vmaddr = le64(p + 24), vmsize = le64(p + 32);
                u64 fileoff = le64(p + 40), filesize = le64(p + 48);
                u32 nsects = le32(p + 64);
                if (g_nsegs < MAX_SEGMENTS) {
                    Seg *s = &g_segs[g_nsegs++];
                    snprintf(s->name, sizeof(s->name), "%s", seg);
                    s->vmaddr = vmaddr;
                    s->vmsize = vmsize;
                    s->fileoff = fileoff;
                    s->filesize = filesize;
                }
                if (!strcmp(seg, "__TEXT") && !have_text) {
                    text_off_vm = vmaddr;
                    text_fileoff = fileoff;
                    have_text = 1;
                }
                for (u32 i = 0; i < nsects && i < 512; i++) {
                    size_t so = p + 72 + (size_t)i * 80;
                    if (so + 80 > p + cmdsize) break;
                    char sect[17], sseg[17];
                    memcpy(sect, B + so, 16);
                    sect[16] = 0;
                    memcpy(sseg, B + so + 16, 16);
                    sseg[16] = 0;
                    add_section(sseg, sect, le64(so + 32), le64(so + 40), le32(so + 48), le32(so + 64));
                }
                break;
            }
            case 0x0D:    // LC_ID_DYLIB
            case 0x0C:    // LC_LOAD_DYLIB
            case 0x80000018:  // LC_LOAD_WEAK_DYLIB
            case 0x8000001F:  // LC_REEXPORT_DYLIB
            case 0x80000023: {  // LC_LOAD_UPWARD_DYLIB
                u32 noff = le32(p + 8);
                if (noff < cmdsize && p + noff < N) {
                    const char *nm = symbol_at(p + noff);
                    if (nm) add_linked(base_name(nm));
                }
                break;
            }
            case 0x26:  // LC_FUNCTION_STARTS
                lc_starts_off = le32(p + 8);
                lc_starts_size = le32(p + 12);
                break;
            case 0x80000034:  // LC_DYLD_CHAINED_FIXUPS
                chain_off = le32(p + 8);
                chain_size = le32(p + 12);
                break;
            case 0x22:  // LC_DYLD_INFO
            case 0x80000022:  // LC_DYLD_INFO_ONLY
                bind_off = le32(p + 16);
                bind_size = le32(p + 20);
                break;
            case 0x02:  // LC_SYMTAB
                symoff = le32(p + 8);
                nsyms = le32(p + 12);
                stroff = le32(p + 16);
                break;
            case 0x32: {  // LC_BUILD_VERSION
                g_platform = le32(p + 8);
                g_minos = le32(p + 12);
                break;
            }
            case 0x25:  // LC_VERSION_MIN_IPHONEOS
                g_platform = 2;
                g_minos = le32(p + 8);
                break;
            default:
                break;
        }
        p += cmdsize;
    }
    switch (g_platform) {
        case 1: g_platform_name = "macOS"; break;
        case 2: g_platform_name = "iOS"; break;
        case 3: g_platform_name = "tvOS"; break;
        case 4: g_platform_name = "watchOS"; break;
        case 6: g_platform_name = "iOS Simulator"; break;
        case 7: g_platform_name = "Mac Catalyst"; break;
        default: g_platform_name = g_platform ? afmt("platform_%u", g_platform) : "未声明"; break;
    }
    if (have_text) g_image_base = text_off_vm - text_fileoff;
    else if (g_nsegs) g_image_base = g_segs[0].vmaddr;

    g_symoff = symoff;
    g_nsyms_raw = nsyms;
    g_stroff = stroff;
    if (symoff && nsyms) load_symtab(symoff, nsyms, stroff);
    if (chain_off) load_chained_fixups(chain_off, chain_size);
    else if (bind_off) load_dyld_bind(bind_off, bind_size);
    if (g_nfix > 1) qsort(g_fix, (size_t)g_nfix, sizeof(Fix), fix_cmp);
    if (lc_starts_off) load_function_starts(lc_starts_off, lc_starts_size);
    return 0;
}

// ---------------------------------------------------------------- ObjC 数据模型

typedef struct {
    const char *sel;
    const char *types;
    u64 imp;
    u8 cls;  // 1 = 类方法
} Method;

typedef struct {
    const char *name, *type;
    u64 offset;
    int have_off;
} Ivar;

typedef struct {
    const char *name, *attrs;
} Prop;

typedef struct {
    const char *name;        // 类名；分类里是分类名
    const char *super_name;
    const char *cls_name;    // 分类所属类名
    u64 va, ro;
    u32 size, start;
    int swift;
    int nmeth, ncls, nivar, nprop, nproto, ncatmeth;
    Method *meth, *clsm;
    Ivar *ivar;
    Prop *prop;
    const char **proto;
    Method *catmeth;      // 分类里的类方法（cls=1）
    Prop *catprop;
} ClassInfo;

static ClassInfo *g_classes;
static int g_nclasses;
static ClassInfo *g_cats;
static int g_ncats;

typedef struct {
    const char *name;
    int nreq, nopt, nprop;
} ProtoInfo;
static ProtoInfo *g_protos;
static int g_nprotos;

#define FAST_DATA_MASK 0x00007ffffffffff8ULL

static int rd32va(u64 va, u32 *out) {
    long o = v2o(va);
    if (o < 0) return 0;
    *out = le32((size_t)o);
    return 1;
}

// 去重集合（va）
static u64 *g_seen;
static size_t g_seen_cap;
static void seen_init(size_t cap) {
    g_seen_cap = cap;
    g_seen = (u64 *)ax(sizeof(u64) * cap);
    if (g_seen) memset(g_seen, 0, sizeof(u64) * cap);
}
static int seen_add(u64 va) {
    if (!g_seen || !g_seen_cap) return 0;
    size_t h = (size_t)((va >> 3) * 0x9E3779B97F4A7C15ULL >> 20) % g_seen_cap;
    for (size_t i = 0; i < g_seen_cap; i++) {
        size_t k = (h + i) % g_seen_cap;
        if (g_seen[k] == 0) { g_seen[k] = va; return 1; }
        if (g_seen[k] == va) return 0;
    }
    return 0;
}

// 方法列表：entsizeAndFlags & 3 决定指针修饰（0=绝对指针 1=相对 selref 2=相对直接字符串）
static int parse_method_list(u64 va, Method **out, int isCls) {
    *out = NULL;
    long o = v2o(va);
    if (o < 0) return 0;
    u32 ef = le32((size_t)o);
    u32 count = le32((size_t)o + 4);
    if (count == 0 || count > 20000) return 0;
    u32 entsize = ef & 0x0000FFFCu;
    int mod = (int)(ef & 3u);
    if (entsize < 12 || entsize > 64) return 0;
    if ((u64)v2o(va) + 8 + (u64)count * entsize > N) return 0;
    Method *m = (Method *)ax(sizeof(Method) * count);
    if (!m) return 0;
    int n = 0;
    for (u32 i = 0; i < count; i++) {
        u64 e = va + 8 + (u64)i * entsize;
        long eo = v2o(e);
        if (eo < 0) break;
        const char *sel = NULL, *types = NULL;
        u64 imp = 0;
        if (entsize >= 24) {
            // 绝对指针：name/types/imp 各 8 字节
            sel = dec_name(e);
            if (!sel) {
                u64 sv = dec(e);
                if (sv) sel = cstr_at(sv);
            }
            u64 tv = dec(e + 8);
            if (tv) types = cstr_at(tv);
            imp = dec(e + 16);
        } else {
            // 相对：三个 int32，各自相对本字段地址
            i32 nrel = (i32)le32((size_t)eo);
            i32 trel = (i32)le32((size_t)eo + 4);
            i32 irel = (i32)le32((size_t)eo + 8);
            if (mod == 2) {
                // relative_direct：直接指向选择器字符串
                sel = cstr_at(e + (u64)(i64)nrel);
            } else {
                // relative：指向 __objc_selrefs 的槽
                u64 slot = e + (u64)(i64)nrel;
                u64 sv = dec(slot);
                if (sv) sel = cstr_at(sv);
                if (!sel) sel = dec_name(slot);
            }
            u64 tsp = e + 4 + (u64)(i64)trel;
            // relative 方法列表里 types 直接指向 __objc_methtype（不经过指针槽）
            types = cstr_at(tsp);
            if (!types) {
                u64 tv = dec(tsp);
                if (tv) types = cstr_at(tv);
            }
            imp = e + 8 + (u64)(i64)irel;
        }
        if (!sel) sel = afmt("<sel@0x%llx>", (unsigned long long)e);
        m[n].sel = sel;
        m[n].types = types;
        m[n].imp = imp;
        m[n].cls = (u8)(isCls ? 1 : 0);
        n++;
    }
    *out = m;
    return n;
}

// 绑定符号名去 ObjC 前缀：_OBJC_CLASS_$_Foo → Foo
static const char *strip_objc_prefix(const char *s) {
    static const char *pre[] = {
        "_OBJC_CLASS_$_", "__OBJC_CLASS_$_", "OBJC_CLASS_$_",
        "_OBJC_METACLASS_$_", "__OBJC_METACLASS_$_", "OBJC_METACLASS_$_",
        "_OBJC_PROTOCOL_$_", "OBJC_PROTOCOL_$_",
    };
    if (!s) return NULL;
    for (size_t i = 0; i < sizeof(pre) / sizeof(pre[0]); i++) {
        size_t n = strlen(pre[i]);
        if (!strncmp(s, pre[i], n)) return s + n;
    }
    return s;
}

static const char *class_name_at(u64 cls) {
    if (!cls) return NULL;
    const char *s = sym_at(cls);
    if (s) return strip_objc_prefix(s);
    u64 ro = dec(cls + 32) & FAST_DATA_MASK;
    if (!ro) return NULL;
    u64 np = dec(ro + 24);
    if (!np) return NULL;
    return cstr_at(np);
}

static int parse_proto_list(u64 va, const char ***out) {
    *out = NULL;
    long o = v2o(va);
    if (o < 0) return 0;
    u64 raw = le64((size_t)o);
    int relative = (raw & 0x8000000000000000ULL) != 0;
    u64 cnt = raw & 0x7FFFFFFFFFFFFFFFULL;
    if (cnt == 0 || cnt > 512) return 0;
    const char **names = (const char **)ax(sizeof(char *) * (size_t)cnt);
    if (!names) return 0;
    int n = 0;
    for (u64 i = 0; i < cnt; i++) {
        u64 ep = va + 8 + i * (relative ? 4 : 8);
        u64 pv = 0;
        if (relative) {
            long eo = v2o(ep);
            if (eo < 0) break;
            pv = ep + (u64)(i64)(i32)le32((size_t)eo);
        } else {
            pv = dec(ep);
        }
        if (!pv) continue;
        u64 np = dec(pv + 8);
        const char *nm = np ? cstr_at(np) : NULL;
        if (!nm) nm = dec_name(pv + 8);
        if (!nm) continue;
        names[n++] = nm;
    }
    *out = names;
    return n;
}

static int parse_ivar_list(u64 va, Ivar **out) {
    *out = NULL;
    long o = v2o(va);
    if (o < 0) return 0;
    u32 ef = le32((size_t)o);
    u32 count = le32((size_t)o + 4);
    if (count == 0 || count > 4000) return 0;
    u32 entsize = ef & 0x0000FFFCu;
    if (entsize < 32 || entsize > 64) entsize = 32;
    Ivar *iv = (Ivar *)ax(sizeof(Ivar) * count);
    if (!iv) return 0;
    int n = 0;
    for (u32 i = 0; i < count; i++) {
        u64 e = va + 8 + (u64)i * entsize;
        long eo = v2o(e);
        if (eo < 0) break;
        Ivar *v = &iv[n];
        memset(v, 0, sizeof(*v));
        u64 offp = dec(e);
        if (offp) {
            u32 ov = 0;
            if (rd32va(offp, &ov)) { v->offset = ov; v->have_off = 1; }
        }
        if (!v->have_off && offp && offp < 0x100000) { v->offset = offp; v->have_off = 1; }
        u64 np = dec(e + 8);
        v->name = np ? cstr_at(np) : NULL;
        u64 tp = dec(e + 16);
        v->type = tp ? cstr_at(tp) : NULL;
        if (!v->name) continue;
        n++;
    }
    *out = iv;
    return n;
}

static int parse_prop_list(u64 va, Prop **out) {
    *out = NULL;
    long o = v2o(va);
    if (o < 0) return 0;
    u32 ef = le32((size_t)o);
    u32 count = le32((size_t)o + 4);
    if (count == 0 || count > 4000) return 0;
    u32 entsize = ef & 0x0000FFFCu;
    if (entsize < 16 || entsize > 64) entsize = 16;
    Prop *pp = (Prop *)ax(sizeof(Prop) * count);
    if (!pp) return 0;
    int n = 0;
    for (u32 i = 0; i < count; i++) {
        u64 e = va + 8 + (u64)i * entsize;
        long eo = v2o(e);
        if (eo < 0) break;
        u64 np = dec(e);
        u64 ap = dec(e + 8);
        Prop *v = &pp[n];
        v->name = np ? cstr_at(np) : NULL;
        v->attrs = ap ? cstr_at(ap) : NULL;
        if (!v->name) continue;
        n++;
    }
    *out = pp;
    return n;
}

static int parse_protocol(u64 va) {
    if (g_nprotos >= MAX_PROTOCOLS) return 0;
    u64 np = dec(va + 8);
    const char *nm = np ? cstr_at(np) : NULL;
    if (!nm) nm = dec_name(va + 8);
    if (!nm) return 0;
    ProtoInfo *pi = &g_protos[g_nprotos];
    memset(pi, 0, sizeof(*pi));
    pi->name = nm;
    Method *tmp = NULL;
    pi->nreq = parse_method_list(dec(va + 24), &tmp, 0) + parse_method_list(dec(va + 32), &tmp, 1);
    pi->nopt = parse_method_list(dec(va + 40), &tmp, 0) + parse_method_list(dec(va + 48), &tmp, 1);
    Prop *pp = NULL;
    pi->nprop = parse_prop_list(dec(va + 56), &pp);
    g_nprotos++;
    return 1;
}

static int parse_class(u64 va) {
    if (g_nclasses >= MAX_CLASSES) return 0;
    if (!seen_add(va)) return 0;
    ClassInfo *ci = &g_classes[g_nclasses];
    memset(ci, 0, sizeof(*ci));
    ci->va = va;
    u64 datap = dec(va + 32);
    ci->swift = (int)(datap & 3ULL) != 0;
    u64 ro = datap & FAST_DATA_MASK;
    ci->ro = ro;
    if (ro) {
        u32 v = 0;
        if (rd32va(ro + 4, &v)) ci->start = v;
        if (rd32va(ro + 8, &v)) ci->size = v;
        u64 np = dec(ro + 24);
        if (np) ci->name = cstr_at(np);
        ci->nmeth = parse_method_list(dec(ro + 32), &ci->meth, 0);
        ci->nproto = parse_proto_list(dec(ro + 40), &ci->proto);
        ci->nivar = parse_ivar_list(dec(ro + 48), &ci->ivar);
        ci->nprop = parse_prop_list(dec(ro + 64), &ci->prop);
    }
    if (!ci->name) ci->name = sym_at(va);
    if (!ci->name) ci->name = afmt("<class@0x%llx>", (unsigned long long)va);
    u64 sp = dec(va + 8);
    if (sp) ci->super_name = class_name_at(sp);
    g_nclasses++;
    return 1;
}

static int parse_category(u64 va) {
    if (g_ncats >= MAX_CATEGORIES) return 0;
    if (!seen_add(va)) return 0;
    ClassInfo *ci = &g_cats[g_ncats];
    memset(ci, 0, sizeof(*ci));
    ci->va = va;
    u64 np = dec(va);
    if (np) ci->name = cstr_at(np);
    u64 cp = dec(va + 8);
    if (cp) ci->cls_name = class_name_at(cp);
    ci->ncatmeth = parse_method_list(dec(va + 16), &ci->catmeth, 0);
    ci->ncls = parse_method_list(dec(va + 24), &ci->clsm, 1);
    ci->nproto = parse_proto_list(dec(va + 32), &ci->proto);
    ci->nprop = parse_prop_list(dec(va + 40), &ci->prop);
    Prop *cprop = NULL;
    int ncprop = parse_prop_list(dec(va + 56), &cprop);
    if (!ci->name) ci->name = sym_at(va);
    if (!ci->name) ci->name = afmt("<category@0x%llx>", (unsigned long long)va);
    g_ncats++;
    (void)ncprop;
    return 1;
}

// 把列表节里的指针逐个交给 fn
static void each_ptr_in(const char *sect, int (*fn)(u64)) {
    const Sect *s = sect_by_name("__DATA", sect);
    if (!s) s = sect_by_name("__DATA_CONST", sect);
    if (!s) s = sect_by_name("__DATA_DIRTY", sect);
    if (!s) s = sect_by_name(NULL, sect);
    if (!s || !s->size) return;
    u64 count = s->size / 8;
    if (count > 100000) count = 100000;
    for (u64 i = 0; i < count; i++) {
        u64 va = s->addr + i * 8;
        u64 p = dec(va);
        if (!p) {
            const char *b = dec_name(va);
            (void)b;
            continue;
        }
        fn(p);
    }
}

static void objc_collect(void) {
    g_classes = (ClassInfo *)ax(sizeof(ClassInfo) * MAX_CLASSES);
    g_cats = (ClassInfo *)ax(sizeof(ClassInfo) * MAX_CATEGORIES);
    g_protos = (ProtoInfo *)ax(sizeof(ProtoInfo) * MAX_PROTOCOLS);
    if (g_classes) memset(g_classes, 0, sizeof(ClassInfo) * MAX_CLASSES);
    if (g_cats) memset(g_cats, 0, sizeof(ClassInfo) * MAX_CATEGORIES);
    if (g_protos) memset(g_protos, 0, sizeof(ProtoInfo) * MAX_PROTOCOLS);
    seen_init(65536);

    each_ptr_in("__objc_protolist", parse_protocol);
    each_ptr_in("__objc_classlist", parse_class);
    each_ptr_in("__objc_nlclslist", parse_class);
    each_ptr_in("__objc_catlist", parse_category);
    each_ptr_in("__objc_catlist2", parse_category);
    each_ptr_in("__objc_nlcatlist", parse_category);
}

// ---------------------------------------------------------------- 字符串与交叉引用

typedef struct {
    u64 va;
    const char *s;
    const char *tag;
    int nx;
    u64 xr[MAX_REFS_PER_STRING];
} StrEnt;
static StrEnt *g_strs;
static int g_nstrs;
static int g_opt_maxstrs = 20000;
static int g_opt_minlen = 4;
static int g_opt_xrefs = 1;

static int str_cmp(const void *a, const void *b) {
    u64 x = ((const StrEnt *)a)->va, y = ((const StrEnt *)b)->va;
    return x < y ? -1 : (x > y ? 1 : 0);
}
static int str_find(u64 va) {
    int lo = 0, hi = g_nstrs - 1;
    while (lo <= hi) {
        int mid = (lo + hi) / 2;
        if (g_strs[mid].va == va) return mid;
        if (g_strs[mid].va < va) lo = mid + 1; else hi = mid - 1;
    }
    return -1;
}

// UTF-8 / ASCII 可打印（含中文等高字节），排除控制字符
static int printable_run(const u8 *p, size_t n) {
    for (size_t i = 0; i < n; i++) {
        u8 c = p[i];
        if (c < 0x20 || c == 0x7F) return 0;
    }
    return 1;
}

static void collect_sect_strings(const char *sect, const char *tag) {
    const Sect *s = sect_by_name(NULL, sect);
    if (!s || !s->size) return;
    long base = v2o(s->addr);
    if (base < 0) return;
    size_t n = (size_t)s->size;
    if ((size_t)base + n > N) n = N - (size_t)base;
    size_t i = 0;
    while (i < n && g_nstrs < g_opt_maxstrs) {
        size_t len = 0;
        while (i + len < n && B[base + i + len]) len++;
        if (len == 0) { i++; continue; }
        if (len >= (size_t)g_opt_minlen && len <= 4000 && printable_run(B + base + i, len)) {
            StrEnt *e = &g_strs[g_nstrs];
            memset(e, 0, sizeof(*e));
            e->va = s->addr + i;
            e->tag = tag;
            e->s = adupn((const char *)(B + base + i), len);
            if (e->s) g_nstrs++;
        }
        i += len + 1;
    }
}

// __cfstring 对象：isa/flags/cstring/length 各 8 字节，按对象地址登记字面量
static void collect_cfstrings(void) {
    const Sect *s = sect_by_name(NULL, "__cfstring");
    if (!s || !s->size) return;
    u64 cnt = s->size / 32;
    if (cnt > 20000) cnt = 20000;
    for (u64 i = 0; i < cnt && g_nstrs < g_opt_maxstrs; i++) {
        u64 va = s->addr + i * 32;
        long o = v2o(va + 16);
        if (o < 0) continue;
        u64 cp = dec(va + 16);
        if (!cp) cp = le64((size_t)o);
        if (!cp) continue;
        const char *sv = cstr_at(cp);
        if (!sv) continue;
        size_t len = strlen(sv);
        if (len < 2 || len > 4000 || !printable_run((const u8 *)sv, len)) continue;
        u64 lraw = dec(va + 24);
        if (lraw && lraw <= len && (u64)len > lraw + 1) len = (size_t)lraw;  // 截断到声明长度
        StrEnt *e = &g_strs[g_nstrs];
        memset(e, 0, sizeof(*e));
        e->va = va;
        e->tag = "__cfstring";
        e->s = adupn(sv, len);
        if (e->s) g_nstrs++;
    }
}

// ---------------------------------------------------------------- stub 与调用图

typedef struct {
    u64 va;
    const char *sel;
} Stub;
static Stub *g_stubs;
static int g_nstubs;

static u64 adrp_page(u64 pc, u32 insn) {
    u64 immlo = (u64)((insn >> 29) & 3u);
    u64 immhi = (u64)((insn >> 5) & 0x7FFFFu);
    u64 imm = (immhi << 2) | immlo;
    if (imm & (1ULL << 20)) imm |= ~((u64)0x1FFFFFULL);
    return (pc & ~0xFFFULL) + (imm << 12);
}

static void stub_add(u64 va, const char *sel) {
    if (g_nstubs >= MAX_STUBS) return;
    g_stubs[g_nstubs].va = va;
    g_stubs[g_nstubs].sel = sel ? adup(sel) : adup("?");
    g_nstubs++;
}
static int stub_index_of(u64 va) {
    int lo = 0, hi = g_nstubs - 1;
    while (lo <= hi) {
        int mid = (lo + hi) / 2;
        if (g_stubs[mid].va == va) return mid;
        if (g_stubs[mid].va < va) lo = mid + 1; else hi = mid - 1;
    }
    return -1;
}

// __objc_stubs 每条是 adrp x1 / ldr x1,[x1] / adrp x16 / ldr x16 / br x16，步长不固定
static void scan_stubs(void) {
    const Sect *s = sect_by_name("__TEXT", "__objc_stubs");
    if (!s || !s->size) return;
    long base = v2o(s->addr);
    if (base < 0) return;
    size_t n = (size_t)s->size;
    if ((size_t)base + n > N) n = N - (size_t)base;
    for (size_t off = 0; off + 16 <= n;) {
        u32 a = le32((size_t)base + off);
        u32 b = le32((size_t)base + off + 4);
        if ((a & 0x9F00001F) == 0x90000001 && (b & 0xFFC003FF) == 0xF9400021) {
            u64 pc = s->addr + off;
            u64 slot = adrp_page(pc, a) + (u64)((b >> 10) & 0xFFF) * 8;
            u64 sv = dec(slot);
            const char *sel = sv ? cstr_at(sv) : NULL;
            if (!sel) sel = dec_name(slot);
            stub_add(pc, sel);
            size_t k = off + 8;
            int adv = 0;
            for (int g = 0; g < 8 && k + 4 <= n; g++, k += 4) {
                u32 insn = le32((size_t)base + k);
                adv = 4 * (g + 3);
                if ((insn & 0xFFFFFC1F) == 0xD61F0000) break;  // br xN
            }
            off += (size_t)(adv > 0 ? adv : 12);
            continue;
        }
        off += 4;
    }
    if (g_nstubs > 1) {
        for (int i = 1; i < g_nstubs; i++) {  // 插入排序，量小
            Stub t = g_stubs[i];
            int j = i - 1;
            while (j >= 0 && g_stubs[j].va > t.va) { g_stubs[j + 1] = g_stubs[j]; j--; }
            g_stubs[j + 1] = t;
        }
    }
}

typedef struct {
    u32 func, stub;
} CallRec;
static CallRec *g_calls;
static int g_ncalls;
static u32 *g_call_first;  // 每函数第一个 call 下标（大小 nfstart+1）

static void note_ref(u64 va, u64 insn) {
    if (!g_opt_xrefs) return;
    int idx = str_find(va);
    if (idx < 0) return;
    StrEnt *s = &g_strs[idx];
    if (s->nx >= MAX_REFS_PER_STRING) return;
    for (int i = 0; i < s->nx; i++)
        if (s->xr[i] == insn) return;
    s->xr[s->nx++] = insn;
}

static void scan_text(void) {
    const Sect *s = sect_by_name("__TEXT", "__text");
    if (!s || !s->size) return;
    long base = v2o(s->addr);
    if (base < 0) return;
    size_t n = (size_t)s->size;
    if ((size_t)base + n > N) n = N - (size_t)base;
    u64 page_v[32], page_pc[32];
    memset(page_v, 0, sizeof(page_v));
    memset(page_pc, 0, sizeof(page_pc));
    for (size_t off = 0; off + 4 <= n; off += 4) {
        u64 pc = s->addr + off;
        u32 i = le32((size_t)base + off);
        if ((i & 0x9F000000) == 0x90000000) {  // adrp xD, page（Rd 不参与匹配）
            int rd = (int)(i & 0x1F);
            page_v[rd] = adrp_page(pc, i);
            page_pc[rd] = pc;
            continue;
        }
        if ((i & 0xFFC00000) == 0xF9400000) {  // ldr xN, [xM, #imm]
            int rn = (int)((i >> 5) & 0x1F), rt = (int)(i & 0x1F);
            if (page_v[rn] && pc - page_pc[rn] <= 256) {
                u64 slot = page_v[rn] + (u64)((i >> 10) & 0xFFF) * 8;
                u64 v = dec(slot);
                if (v) note_ref(v, pc);
                if (rt == rn) page_v[rn] = 0;
            }
            continue;
        }
        if ((i & 0x7F000000) == 0x11000000) {  // add xD, xN, #imm
            int rn = (int)((i >> 5) & 0x1F), rd = (int)(i & 0x1F);
            u64 imm = (u64)((i >> 10) & 0xFFF);
            if ((i >> 22) & 1) imm <<= 12;
            if (page_v[rn] && pc - page_pc[rn] <= 256) {
                note_ref(page_v[rn] + imm, pc);
                if (rd != rn) { page_v[rd] = page_v[rn]; page_pc[rd] = page_pc[rn]; }
            }
            continue;
        }
        if ((i & 0xFC000000) == 0x94000000) {  // bl
            i32 imm = (i32)(i & 0x03FFFFFF);
            if (imm & 0x02000000) imm |= (i32)0xFC000000;
            u64 target = pc + (u64)((i64)imm * 4);
            int si = stub_index_of(target);
            if (si >= 0 && g_ncalls < MAX_CALLS) {
                int fi = func_index_of(pc);
                if (fi >= 0) {
                    g_calls[g_ncalls].func = (u32)fi;
                    g_calls[g_ncalls].stub = (u32)si;
                    g_ncalls++;
                }
            }
            continue;
        }
        if ((i & 0xFC000000) == 0x14000000) {  // b（尾调用到 stub）
            i32 imm = (i32)(i & 0x03FFFFFF);
            if (imm & 0x02000000) imm |= (i32)0xFC000000;
            u64 target = pc + (u64)((i64)imm * 4);
            int si = stub_index_of(target);
            if (si >= 0 && g_ncalls < MAX_CALLS) {
                int fi = func_index_of(pc);
                if (fi >= 0) {
                    g_calls[g_ncalls].func = (u32)fi;
                    g_calls[g_ncalls].stub = (u32)si;
                    g_ncalls++;
                }
            }
            continue;
        }
    }
}

static int call_cmp(const void *a, const void *b) {
    const CallRec *x = (const CallRec *)a, *y = (const CallRec *)b;
    if (x->func != y->func) return x->func < y->func ? -1 : 1;
    if (x->stub != y->stub) return x->stub < y->stub ? -1 : 1;
    return 0;
}

static void finish_calls(void) {
    g_call_first = (u32 *)ax(sizeof(u32) * (size_t)(g_nfstart + 1));
    if (!g_call_first) return;
    memset(g_call_first, 0, sizeof(u32) * (size_t)(g_nfstart + 1));
    if (g_ncalls == 0) return;
    qsort(g_calls, (size_t)g_ncalls, sizeof(CallRec), call_cmp);
    int w = 0;
    for (int i = 0; i < g_ncalls; i++) {
        if (w > 0 && g_calls[w - 1].func == g_calls[i].func && g_calls[w - 1].stub == g_calls[i].stub) continue;
        g_calls[w++] = g_calls[i];
    }
    g_ncalls = w;
    for (int i = 0; i < g_ncalls; i++) g_call_first[g_calls[i].func + 1]++;
    for (int i = 1; i <= g_nfstart; i++) g_call_first[i] += g_call_first[i - 1];
}

// 方法实现地址 → 标签（-/+[Class sel]），用于给函数命名
typedef struct {
    u64 imp;
    const char *label;
} ImpEnt;
static ImpEnt *g_imps;
static int g_nimps;

static int imp_cmp(const void *a, const void *b) {
    u64 x = ((const ImpEnt *)a)->imp, y = ((const ImpEnt *)b)->imp;
    return x < y ? -1 : (x > y ? 1 : 0);
}
static const char *imp_label(u64 imp) {
    if (!imp || !g_nimps) return NULL;
    int lo = 0, hi = g_nimps - 1;
    while (lo <= hi) {
        int mid = (lo + hi) / 2;
        if (g_imps[mid].imp == imp) return g_imps[mid].label;
        if (g_imps[mid].imp < imp) lo = mid + 1; else hi = mid - 1;
    }
    return NULL;
}
static void build_imps(void) {
    int cap = 0;
    for (int i = 0; i < g_nclasses; i++)
        cap += g_classes[i].nmeth + g_classes[i].ncls;
    for (int i = 0; i < g_ncats; i++)
        cap += g_cats[i].ncatmeth + g_cats[i].ncls;
    if (cap <= 0) return;
    g_imps = (ImpEnt *)ax(sizeof(ImpEnt) * (size_t)cap);
    if (!g_imps) return;
    for (int ci = 0; ci < g_nclasses; ci++) {
        ClassInfo *c = &g_classes[ci];
        for (int k = 0; k < c->nmeth + c->ncls; k++) {
            Method *m = k < c->nmeth ? &c->meth[k] : &c->clsm[k - c->nmeth];
            if (!m->imp || g_nimps >= cap) continue;
            g_imps[g_nimps].imp = m->imp;
            g_imps[g_nimps].label = afmt("%c[%s %s]", m->cls ? '+' : '-', c->name, m->sel);
            g_nimps++;
        }
    }
    for (int ci = 0; ci < g_ncats; ci++) {
        ClassInfo *c = &g_cats[ci];
        for (int k = 0; k < c->ncatmeth + c->ncls; k++) {
            Method *m = k < c->ncatmeth ? &c->catmeth[k] : &c->clsm[k - c->ncatmeth];
            if (!m->imp || g_nimps >= cap) continue;
            g_imps[g_nimps].imp = m->imp;
            g_imps[g_nimps].label = afmt("%c[%s(%s) %s]", m->cls ? '+' : '-', c->cls_name ? c->cls_name : "?",
                                        c->name, m->sel);
            g_nimps++;
        }
    }
    if (g_nimps > 1) qsort(g_imps, (size_t)g_nimps, sizeof(ImpEnt), imp_cmp);
}

static const char *func_label(int idx, char *buf, size_t cap) {
    if (idx < 0 || idx >= g_nfstart) return "?";
    u64 va = g_fstart[idx];
    const char *l = imp_label(va);
    if (l) return l;
    l = sym_at(va);
    if (l) return l;
    int si = stub_index_of(va);
    if (si >= 0) {
        snprintf(buf, cap, "stub:%s", g_stubs[si].sel);
        return buf;
    }
    snprintf(buf, cap, "sub_0x%llx", (unsigned long long)va);
    return buf;
}

// ---------------------------------------------------------------- 导入符号与关键字

static const char **g_imports;
static int g_nimports;

static void collect_imports(void) {
    if (g_nfix <= 0) return;
    g_imports = (const char **)ax(sizeof(char *) * 4096);
    if (!g_imports) return;
    for (int i = 0; i < g_nfix; i++) {
        if (!g_fix[i].bind || !g_fix[i].name) continue;
        int dup = 0;
        for (int k = 0; k < g_nimports; k++) {
            if (!strcmp(g_imports[k], g_fix[i].name)) { dup = 1; break; }
        }
        if (dup) continue;
        if (g_nimports >= 4096) break;
        g_imports[g_nimports++] = g_fix[i].name;
    }
}

static int ci_has(const char *s, const char *sub) {
    if (!s || !sub) return 0;
    size_t n = strlen(sub);
    for (const char *p = s; *p; p++) {
        size_t i = 0;
        while (i < n && p[i] && (char)((p[i] >= 'A' && p[i] <= 'Z') ? p[i] + 32 : p[i]) ==
                                       (char)((sub[i] >= 'A' && sub[i] <= 'Z') ? sub[i] + 32 : sub[i]))
            i++;
        if (i == n) return 1;
    }
    return 0;
}

// 粗分类：给报告里“关键字符串”打标
static const char *keyword_tag(const char *s) {
    if (!s) return NULL;
    if (!strncmp(s, "http://", 7) || !strncmp(s, "https://", 8)) return "url";
    if (ci_has(s, "vip") || ci_has(s, "purchase") || ci_has(s, "order") || ci_has(s, "iap") ||
        ci_has(s, "paid") || ci_has(s, "unlock") || ci_has(s, "pro_") || ci_has(s, "subscri") ||
        ci_has(s, "pay") || ci_has(s, "coin") || ci_has(s, "会员") || ci_has(s, "内购") ||
        ci_has(s, "购买") || ci_has(s, "支付"))
        return "pay";
    if (ci_has(s, "token") || ci_has(s, "secret") || ci_has(s, "password") || ci_has(s, "passwd") ||
        ci_has(s, "api_key") || ci_has(s, "apikey") || ci_has(s, "sign") || ci_has(s, "license") ||
        ci_has(s, "密钥") || ci_has(s, "授权"))
        return "key";
    if (s[0] == '/' || ci_has(s, "/var/mobile") || ci_has(s, "/library/")) return "path";
    if (ci_has(s, "alert") || ci_has(s, "toast") || ci_has(s, "hud") || ci_has(s, "hook") ||
        ci_has(s, "patch") || ci_has(s, "inject"))
        return "ui";
    return NULL;
}

// ---------------------------------------------------------------- JSON

static void j_addr(SB *b, u64 v) {
    char t[32];
    snprintf(t, sizeof(t), "0x%llx", (unsigned long long)v);
    sb_add(b, "\"", 1);
    sb_puts(b, t);
    sb_add(b, "\"", 1);
}
static void j_methods(SB *b, const Method *m, int n) {
    sb_add(b, "[", 1);
    for (int i = 0; i < n; i++) {
        if (i) sb_add(b, ",", 1);
        sb_puts(b, "{\"name\":");
        sb_jstr(b, m[i].sel);
        sb_puts(b, ",\"types\":");
        sb_jstr(b, m[i].types);
        sb_puts(b, ",\"imp\":");
        j_addr(b, m[i].imp);
        sb_puts(b, ",\"class_method\":");
        sb_puts(b, m[i].cls ? "true" : "false");
        sb_add(b, "}", 1);
    }
    sb_add(b, "]", 1);
}
static void j_ivars(SB *b, const Ivar *v, int n) {
    sb_add(b, "[", 1);
    for (int i = 0; i < n; i++) {
        if (i) sb_add(b, ",", 1);
        sb_puts(b, "{\"name\":");
        sb_jstr(b, v[i].name);
        sb_puts(b, ",\"type\":");
        sb_jstr(b, v[i].type);
        if (v[i].have_off) {
            sb_puts(b, ",\"offset\":");
            char t[24];
            snprintf(t, sizeof(t), "%llu", (unsigned long long)v[i].offset);
            sb_puts(b, t);
        }
        sb_add(b, "}", 1);
    }
    sb_add(b, "]", 1);
}
static void j_props(SB *b, const Prop *p, int n) {
    sb_add(b, "[", 1);
    for (int i = 0; i < n; i++) {
        if (i) sb_add(b, ",", 1);
        sb_puts(b, "{\"name\":");
        sb_jstr(b, p[i].name);
        sb_puts(b, ",\"attributes\":");
        sb_jstr(b, p[i].attrs);
        sb_add(b, "}", 1);
    }
    sb_add(b, "]", 1);
}
static void j_strs(SB *b, const char **s, int n) {
    sb_add(b, "[", 1);
    for (int i = 0; i < n; i++) {
        if (i) sb_add(b, ",", 1);
        sb_jstr(b, s[i]);
    }
    sb_add(b, "]", 1);
}

// 一个类/分类的方法调用了哪些选择器（去重，最多 cap 条）
static int class_calls(const ClassInfo *c, const char **out, int cap) {
    if (!g_call_first || !g_ncalls) return 0;
    int n = 0;
    int total = c->nmeth + c->ncls;
    for (int k = 0; k < total; k++) {
        const Method *m = k < c->nmeth ? &c->meth[k] : &c->clsm[k - c->nmeth];
        int fi = func_index_of(m->imp);
        if (fi < 0) continue;
        for (u32 ci = g_call_first[fi]; ci < g_call_first[fi + 1] && ci < (u32)g_ncalls; ci++) {
            const char *sel = g_stubs[g_calls[ci].stub].sel;
            int dup = 0;
            for (int j = 0; j < n; j++)
                if (!strcmp(out[j], sel)) { dup = 1; break; }
            if (dup || n >= cap) continue;
            out[n++] = sel;
        }
    }
    return n;
}
// 分类的调用（实例方法在 catmeth，类方法在 clsm）
static int cat_calls(const ClassInfo *c, const char **out, int cap) {
    if (!g_call_first || !g_ncalls) return 0;
    int n = 0;
    int total = c->ncatmeth + c->ncls;
    for (int k = 0; k < total; k++) {
        const Method *m = k < c->ncatmeth ? &c->catmeth[k] : &c->clsm[k - c->ncatmeth];
        int fi = func_index_of(m->imp);
        if (fi < 0) continue;
        for (u32 ci = g_call_first[fi]; ci < g_call_first[fi + 1] && ci < (u32)g_ncalls; ci++) {
            const char *sel = g_stubs[g_calls[ci].stub].sel;
            int dup = 0;
            for (int j = 0; j < n; j++)
                if (!strcmp(out[j], sel)) { dup = 1; break; }
            if (dup || n >= cap) continue;
            out[n++] = sel;
        }
    }
    return n;
}

// 汇总类/分类的方法、ivar、属性数（类方法记在 clsm/ncls 里）
static void count_aggregate(int *meth, int *ivar, int *prop) {
    int m = 0, iv = 0, pr = 0;
    for (int i = 0; i < g_nclasses; i++) {
        m += g_classes[i].nmeth + g_classes[i].ncls;
        iv += g_classes[i].nivar;
        pr += g_classes[i].nprop;
    }
    for (int i = 0; i < g_ncats; i++) {
        m += g_cats[i].nmeth + g_cats[i].ncls + g_cats[i].ncatmeth;
        iv += g_cats[i].nivar;
        pr += g_cats[i].nprop;
    }
    *meth = m;
    *ivar = iv;
    *prop = pr;
}

static void j_header(SB *b, const char *path) {
    sb_puts(b, "{\n\"engine\":");
    sb_jstr(b, "xosvi-re " XRE_VERSION);
    sb_puts(b, ",\n\"file\":");
    sb_jstr(b, path);
    sb_puts(b, ",\n\"size\":");
    char t[32];
    snprintf(t, sizeof(t), "%llu", (unsigned long long)g_filesize);
    sb_puts(b, t);
    sb_puts(b, ",\n\"arch\":");
    sb_jstr(b, g_arch_name);
    sb_puts(b, ",\n\"type\":");
    sb_jstr(b, g_filetype_name);
    sb_puts(b, ",\n\"platform\":");
    sb_jstr(b, ver_str(g_minos));
    sb_puts(b, ",\n\"os\":");
    sb_jstr(b, g_platform_name);
    sb_puts(b, ",\n\"image_base\":");
    j_addr(b, g_image_base);
    sb_puts(b, ",\n\"counts\":{");
    int agg_m = 0, agg_i = 0, agg_p = 0;
    count_aggregate(&agg_m, &agg_i, &agg_p);
    char line[512];
    snprintf(line, sizeof(line),
             "\"classes\":%d,\"categories\":%d,\"protocols\":%d,\"methods\":%d,\"ivars\":%d,"
             "\"properties\":%d,\"strings\":%d,\"functions\":%d,\"stubs\":%d,\"imports\":%d,"
             "\"binds\":%d,\"rebases\":%d",
             g_nclasses, g_ncats, g_nprotos, agg_m, agg_i, agg_p, g_nstrs, g_nfstart, g_nstubs,
             g_nimports, g_binds, g_rebases);
    sb_puts(b, line);
    sb_puts(b, "}");
}

static void j_sections(SB *b) {
    sb_puts(b, ",\n\"sections\":[");
    for (int i = 0; i < g_nsects; i++) {
        const Sect *s = &g_sects[i];
        if (i) sb_add(b, ",", 1);
        sb_puts(b, "{\"seg\":");
        sb_jstr(b, s->seg);
        sb_puts(b, ",\"sect\":");
        sb_jstr(b, s->sect);
        sb_puts(b, ",\"addr\":");
        j_addr(b, s->addr);
        char t[64];
        snprintf(t, sizeof(t), ",\"size\":%llu,\"fileoff\":%u}", (unsigned long long)s->size, s->off);
        sb_puts(b, t);
    }
    sb_add(b, "]", 1);
}
static void j_linked(SB *b) {
    sb_puts(b, ",\n\"linked\":");
    j_strs(b, (const char **)g_linked, g_nlinked);
    sb_puts(b, ",\n\"imports\":");
    j_strs(b, g_imports, g_nimports);
}
static void j_classes(SB *b) {
    sb_puts(b, ",\n\"classes\":[");
    for (int i = 0; i < g_nclasses; i++) {
        ClassInfo *c = &g_classes[i];
        if (i) sb_add(b, ",", 1);
        sb_puts(b, "\n{\"name\":");
        sb_jstr(b, c->name);
        sb_puts(b, ",\"super\":");
        sb_jstr(b, c->super_name);
        sb_puts(b, ",\"addr\":");
        j_addr(b, c->va);
        char t[64];
        snprintf(t, sizeof(t), ",\"instance_size\":%u,\"swift\":%s", c->size, c->swift ? "true" : "false");
        sb_puts(b, t);
        sb_puts(b, ",\"protocols\":");
        j_strs(b, c->proto, c->nproto);
        sb_puts(b, ",\"methods\":");
        j_methods(b, c->meth, c->nmeth);
        if (c->ncls) {
            sb_puts(b, ",\"class_methods\":");
            j_methods(b, c->clsm, c->ncls);
        }
        sb_puts(b, ",\"ivars\":");
        j_ivars(b, c->ivar, c->nivar);
        sb_puts(b, ",\"properties\":");
        j_props(b, c->prop, c->nprop);
        const char *calls[64];
        int nc = class_calls(c, calls, 64);
        sb_puts(b, ",\"calls\":");
        j_strs(b, calls, nc);
        sb_add(b, "}", 1);
    }
    sb_add(b, "]", 1);
}
static void j_categories(SB *b) {
    sb_puts(b, ",\n\"categories\":[");
    for (int i = 0; i < g_ncats; i++) {
        ClassInfo *c = &g_cats[i];
        if (i) sb_add(b, ",", 1);
        sb_puts(b, "\n{\"name\":");
        sb_jstr(b, c->name);
        sb_puts(b, ",\"on_class\":");
        sb_jstr(b, c->cls_name);
        sb_puts(b, ",\"addr\":");
        j_addr(b, c->va);
        sb_puts(b, ",\"protocols\":");
        j_strs(b, c->proto, c->nproto);
        sb_puts(b, ",\"methods\":");
        j_methods(b, c->catmeth, c->ncatmeth);
        sb_puts(b, ",\"class_methods\":");
        j_methods(b, c->clsm, c->ncls);
        sb_puts(b, ",\"properties\":");
        j_props(b, c->prop, c->nprop);
        const char *calls[64];
        int nc = cat_calls(c, calls, 64);
        sb_puts(b, ",\"calls\":");
        j_strs(b, calls, nc);
        sb_add(b, "}", 1);
    }
    sb_add(b, "]", 1);
}
static void j_protocols(SB *b) {
    sb_puts(b, ",\n\"protocols\":[");
    for (int i = 0; i < g_nprotos; i++) {
        ProtoInfo *p = &g_protos[i];
        if (i) sb_add(b, ",", 1);
        sb_puts(b, "{\"name\":");
        sb_jstr(b, p->name);
        char t[96];
        snprintf(t, sizeof(t), ",\"required\":%d,\"optional\":%d,\"properties\":%d}", p->nreq, p->nopt, p->nprop);
        sb_puts(b, t);
    }
    sb_add(b, "]", 1);
}
static void j_strings(SB *b) {
    sb_puts(b, ",\n\"strings\":[");
    int first = 1;
    for (int i = 0; i < g_nstrs; i++) {
        StrEnt *s = &g_strs[i];
        if (!first) sb_add(b, ",", 1);
        first = 0;
        sb_puts(b, "\n{\"addr\":");
        j_addr(b, s->va);
        sb_puts(b, ",\"section\":");
        sb_jstr(b, s->tag);
        sb_puts(b, ",\"value\":");
        sb_jstr(b, s->s);
        const char *kw = keyword_tag(s->s);
        if (kw) {
            sb_puts(b, ",\"tag\":");
            sb_jstr(b, kw);
        }
        if (s->nx) {
            sb_puts(b, ",\"xrefs\":[");
            for (int k = 0; k < s->nx; k++) {
                if (k) sb_add(b, ",", 1);
                sb_puts(b, "{\"addr\":");
                j_addr(b, s->xr[k]);
                int fi = func_index_of(s->xr[k]);
                if (fi >= 0) {
                    char lb[256];
                    sb_puts(b, ",\"func\":");
                    sb_jstr(b, func_label(fi, lb, sizeof(lb)));
                }
                sb_add(b, "}", 1);
            }
            sb_add(b, "]", 1);
        }
        sb_add(b, "}", 1);
    }
    sb_add(b, "]", 1);
}
static void j_functions(SB *b) {
    sb_puts(b, ",\n\"functions\":[");
    char lb[256];
    int emitted = 0;
    for (int i = 0; i < g_nfstart; i++) {
        if (!g_call_first) break;
        u32 a = g_call_first[i], z = g_call_first[i + 1];
        if (z <= a) continue;
        if (emitted++) sb_add(b, ",", 1);
        sb_puts(b, "\n{\"addr\":");
        j_addr(b, g_fstart[i]);
        sb_puts(b, ",\"name\":");
        sb_jstr(b, func_label(i, lb, sizeof(lb)));
        sb_puts(b, ",\"calls\":[");
        for (u32 c = a; c < z && c < (u32)g_ncalls; c++) {
            if (c > a) sb_add(b, ",", 1);
            sb_jstr(b, g_stubs[g_calls[c].stub].sel);
        }
        sb_add(b, "]", 1);
        sb_add(b, "}", 1);
    }
    sb_add(b, "]", 1);
}

// ---------------------------------------------------------------- Markdown

static void totals(int *meth, int *ivar, int *prop) {
    int m = 0, i2 = 0, p = 0;
    for (int i = 0; i < g_nclasses; i++) {
        m += g_classes[i].nmeth + g_classes[i].ncls;
        i2 += g_classes[i].nivar;
        p += g_classes[i].nprop;
    }
    for (int i = 0; i < g_ncats; i++) {
        m += g_cats[i].ncatmeth + g_cats[i].ncls;
        p += g_cats[i].nprop;
    }
    *meth = m;
    *ivar = i2;
    *prop = p;
}

static void md_method_table(SB *b, const Method *m, int n, const char *title) {
    if (n <= 0) return;
    sb_puts(b, "\n**");
    sb_puts(b, title);
    sb_puts(b, "**\n\n| 选择器 | 类型编码 | 实现 |\n|---|---|---|\n");
    for (int i = 0; i < n; i++) {
        sb_puts(b, "| `");
        sb_puts(b, md_cell(m[i].sel));
        sb_puts(b, "` | ");
        sb_puts(b, m[i].types ? md_cell(m[i].types) : "-");
        sb_puts(b, " | ");
        char t[32];
        snprintf(t, sizeof(t), "0x%llx", (unsigned long long)m[i].imp);
        sb_puts(b, t);
        sb_puts(b, " |\n");
    }
}

static void md_report(SB *b, const char *path) {
    int meth = 0, ivar = 0, prop = 0;
    totals(&meth, &ivar, &prop);
    char t[128];
    sb_puts(b, "# ");
    sb_puts(b, base_name(path));
    sb_puts(b, " 逆向分析报告\n\n> 由 Xosvi 内置逆向引擎 xosvi-re " XRE_VERSION
               " 生成 · 纯静态解析，未运行目标代码\n");

    sb_puts(b, "\n## 一、概要\n\n| 项目 | 值 |\n|---|---|\n| 文件 | `");
    sb_puts(b, path);
    sb_puts(b, "` |\n");
    snprintf(t, sizeof(t), "| 大小 | %llu B（%llu KB） |\n", (unsigned long long)g_filesize,
             (unsigned long long)(g_filesize / 1024));
    sb_puts(b, t);
    sb_puts(b, "| 架构 | ");
    sb_puts(b, g_arch_name);
    sb_puts(b, " |\n| 类型 | ");
    sb_puts(b, g_filetype_name);
    sb_puts(b, " |\n| 平台 | ");
    sb_puts(b, g_platform_name);
    sb_puts(b, " ");
    sb_puts(b, ver_str(g_minos));
    sb_puts(b, " |\n| Image Base | ");
    snprintf(t, sizeof(t), "0x%llx", (unsigned long long)g_image_base);
    sb_puts(b, t);
    sb_puts(b, " |\n");
    snprintf(t, sizeof(t), "| 类 / 分类 / 协议 | %d / %d / %d |\n", g_nclasses, g_ncats, g_nprotos);
    sb_puts(b, t);
    snprintf(t, sizeof(t), "| 方法 / ivar / 属性 | %d / %d / %d |\n", meth, ivar, prop);
    sb_puts(b, t);
    snprintf(t, sizeof(t), "| 字符串 / 函数 / stub | %d / %d / %d |\n", g_nstrs, g_nfstart, g_nstubs);
    sb_puts(b, t);
    snprintf(t, sizeof(t), "| 导入符号 / bind / rebase | %d / %d / %d |\n", g_nimports, g_binds, g_rebases);
    sb_puts(b, t);

    sb_puts(b, "\n## 二、依赖的动态库\n\n");
    if (!g_nlinked) sb_puts(b, "- （未声明）\n");
    for (int i = 0; i < g_nlinked; i++) {
        sb_puts(b, "- `");
        sb_puts(b, g_linked[i]);
        sb_puts(b, "`\n");
    }

    sb_puts(b, "\n## 三、段与节\n\n| 段 | 节 | 地址 | 大小 | 文件偏移 |\n|---|---|---|---|---|\n");
    for (int i = 0; i < g_nsects; i++) {
        const Sect *s = &g_sects[i];
        sb_puts(b, "| ");
        sb_puts(b, s->seg);
        sb_puts(b, " | ");
        sb_puts(b, s->sect);
        sb_puts(b, " | ");
        snprintf(t, sizeof(t), "0x%llx", (unsigned long long)s->addr);
        sb_puts(b, t);
        snprintf(t, sizeof(t), " | %llu | ", (unsigned long long)s->size);
        sb_puts(b, t);
        snprintf(t, sizeof(t), "0x%x |\n", s->off);
        sb_puts(b, t);
    }

    sb_puts(b, "\n## 四、类清单\n\n| 类 | 父类 | 方法 | 属性 | ivar | 协议 |\n|---|---|---|---|---|---|\n");
    for (int i = 0; i < g_nclasses; i++) {
        ClassInfo *c = &g_classes[i];
        sb_puts(b, "| `");
        sb_puts(b, md_cell(c->name));
        sb_puts(b, "` | ");
        sb_puts(b, c->super_name ? md_cell(c->super_name) : "-");
        sb_puts(b, " | ");
        snprintf(t, sizeof(t), "%d | %d | %d | ", c->nmeth + c->ncls, c->nprop, c->nivar);
        sb_puts(b, t);
        if (c->nproto) {
            for (int k = 0; k < c->nproto; k++) {
                sb_puts(b, k ? ", " : "");
                sb_puts(b, c->proto[k]);
            }
        } else {
            sb_puts(b, "-");
        }
        sb_puts(b, " |\n");
    }

    sb_puts(b, "\n## 五、类详情\n");
    for (int i = 0; i < g_nclasses; i++) {
        ClassInfo *c = &g_classes[i];
        sb_puts(b, "\n### `");
        sb_puts(b, c->name);
        sb_puts(b, "`");
        sb_puts(b, c->swift ? "（Swift）" : "");
        sb_puts(b, "\n\n- 父类：");
        sb_puts(b, c->super_name ? c->super_name : "（未声明）");
        snprintf(t, sizeof(t), "\n- 实例大小：%u 字节\n- 类对象地址：0x%llx\n", c->size,
                 (unsigned long long)c->va);
        sb_puts(b, t);
        if (c->nproto) {
            sb_puts(b, "- 协议：");
            for (int k = 0; k < c->nproto; k++) sb_puts(b, k ? ", " : ""), sb_puts(b, c->proto[k]);
            sb_puts(b, "\n");
        }
        md_method_table(b, c->meth, c->nmeth, "实例方法");
        md_method_table(b, c->clsm, c->ncls, "类方法");
        if (c->nprop) {
            sb_puts(b, "\n**属性**\n\n| 属性 | 特性 |\n|---|---|\n");
            for (int k = 0; k < c->nprop; k++) {
                sb_puts(b, "| `");
                sb_puts(b, md_cell(c->prop[k].name));
                sb_puts(b, "` | ");
                sb_puts(b, c->prop[k].attrs ? md_cell(c->prop[k].attrs) : "-");
                sb_puts(b, " |\n");
            }
        }
        if (c->nivar) {
            sb_puts(b, "\n**实例变量**\n\n| ivar | 类型 | 偏移 |\n|---|---|---|\n");
            for (int k = 0; k < c->nivar; k++) {
                sb_puts(b, "| `");
                sb_puts(b, md_cell(c->ivar[k].name));
                sb_puts(b, "` | ");
                sb_puts(b, c->ivar[k].type ? md_cell(c->ivar[k].type) : "-");
                sb_puts(b, " | ");
                if (c->ivar[k].have_off) snprintf(t, sizeof(t), "%llu", (unsigned long long)c->ivar[k].offset);
                else snprintf(t, sizeof(t), "-");
                sb_puts(b, t);
                sb_puts(b, " |\n");
            }
        }
        const char *calls[64];
        int nc = class_calls(c, calls, 64);
        if (nc) {
            sb_puts(b, "\n**调用的选择器**（来自方法实现里的 objc_msgSend stub）\n\n");
            for (int k = 0; k < nc; k++) {
                sb_puts(b, "`");
                sb_puts(b, calls[k]);
                sb_puts(b, "` ");
            }
            sb_puts(b, "\n");
        }
    }

    sb_puts(b, "\n## 六、分类\n");
    if (!g_ncats) sb_puts(b, "\n（无）\n");
    for (int i = 0; i < g_ncats; i++) {
        ClassInfo *c = &g_cats[i];
        sb_puts(b, "\n### `");
        sb_puts(b, c->name);
        sb_puts(b, "` → ");
        sb_puts(b, c->cls_name ? c->cls_name : "（未知类）");
        sb_puts(b, "\n");
        md_method_table(b, c->catmeth, c->ncatmeth, "实例方法");
        md_method_table(b, c->clsm, c->ncls, "类方法");
        const char *calls[64];
        int nc = cat_calls(c, calls, 64);
        if (nc) {
            sb_puts(b, "\n**调用的选择器**\n\n");
            for (int k = 0; k < nc; k++) {
                sb_puts(b, "`");
                sb_puts(b, calls[k]);
                sb_puts(b, "` ");
            }
            sb_puts(b, "\n");
        }
    }

    sb_puts(b, "\n## 七、协议\n\n");
    if (!g_nprotos) sb_puts(b, "（无）\n");
    else {
        sb_puts(b, "| 协议 | 必需方法 | 可选方法 | 属性 |\n|---|---|---|---|\n");
        for (int i = 0; i < g_nprotos; i++) {
            ProtoInfo *p = &g_protos[i];
            sb_puts(b, "| `");
            sb_puts(b, md_cell(p->name));
            sb_puts(b, "` | ");
            snprintf(t, sizeof(t), "%d | %d | %d |\n", p->nreq, p->nopt, p->nprop);
            sb_puts(b, t);
        }
    }

    sb_puts(b, "\n## 八、关键字符串与交叉引用\n\n");
    sb_puts(b, "只列出带关键字标记或被代码引用的字符串。完整清单见 `report.json` 的 `strings`。\n\n");
    sb_puts(b, "| 地址 | 节 | 标记 | 值 | 引用函数 |\n|---|---|---|---|---|\n");
    int shown = 0;
    for (int i = 0; i < g_nstrs && shown < 400; i++) {
        StrEnt *s = &g_strs[i];
        const char *kw = keyword_tag(s->s);
        if (!kw && s->nx == 0) continue;
        shown++;
        snprintf(t, sizeof(t), "| 0x%llx | ", (unsigned long long)s->va);
        sb_puts(b, t);
        sb_puts(b, s->tag);
        sb_puts(b, " | ");
        sb_puts(b, kw ? kw : "-");
        sb_puts(b, " | `");
        char *cell = md_cell(s->s);
        if (strlen(cell) > 160) cell[160] = 0;
        sb_puts(b, cell);
        sb_puts(b, "` | ");
        if (!s->nx) sb_puts(b, "-");
        for (int k = 0; k < s->nx; k++) {
            int fi = func_index_of(s->xr[k]);
            char lb[256];
            if (k) sb_puts(b, "<br>");
            snprintf(t, sizeof(t), "0x%llx ", (unsigned long long)s->xr[k]);
            sb_puts(b, t);
            sb_puts(b, fi >= 0 ? func_label(fi, lb, sizeof(lb)) : "?");
        }
        sb_puts(b, " |\n");
    }
    if (!shown) sb_puts(b, "| - | - | - | （无匹配） | - |\n");

    sb_puts(b, "\n## 九、函数与调用\n\n");
    sb_puts(b, "只列出能对应到 objc_msgSend stub 的函数（方法实现与 C 函数）。\n\n");
    sb_puts(b, "| 函数 | 地址 | 调用的选择器 |\n|---|---|---|\n");
    int fn = 0;
    for (int i = 0; i < g_nfstart && fn < 400; i++) {
        if (!g_call_first) break;
        u32 a = g_call_first[i], z = g_call_first[i + 1];
        if (z <= a) continue;
        fn++;
        char lb[256];
        sb_puts(b, "| `");
        sb_puts(b, md_cell(func_label(i, lb, sizeof(lb))));
        sb_puts(b, "` | ");
        snprintf(t, sizeof(t), "0x%llx | ", (unsigned long long)g_fstart[i]);
        sb_puts(b, t);
        for (u32 c = a; c < z && c < (u32)g_ncalls; c++) {
            sb_puts(b, "`");
            sb_puts(b, md_cell(g_stubs[g_calls[c].stub].sel));
            sb_puts(b, "` ");
        }
        sb_puts(b, " |\n");
    }
    if (!fn) sb_puts(b, "| - | - | （未识别到调用） |\n");

    sb_puts(b, "\n## 十、导入符号\n\n");
    if (!g_nimports) sb_puts(b, "（无）\n");
    else {
        for (int i = 0; i < g_nimports; i++) {
            sb_puts(b, "- `");
            sb_puts(b, g_imports[i]);
            sb_puts(b, "`\n");
        }
    }
    sb_puts(b, "\n---\n\n由 xosvi-re 静态解析生成；地址均为文件内虚拟地址，未加 A/B 偏移。\n");
}

// ---------------------------------------------------------------- 驱动

static void engine_free(void) {
    g_imps = NULL;
    g_imports = NULL;
    g_syms = NULL;
    free(g_segs); g_segs = NULL; g_nsegs = 0;
    free(g_sects); g_sects = NULL; g_nsects = 0;
    free(g_fix); g_fix = NULL; g_nfix = 0; g_binds = 0; g_rebases = 0;
    free(g_fstart); g_fstart = NULL; g_nfstart = 0;
    free(g_stubs); g_stubs = NULL; g_nstubs = 0;
    free(g_calls); g_calls = NULL; g_ncalls = 0;
    g_call_first = NULL;  // arena 分配，随 arena_reset 释放
    free(g_strs); g_strs = NULL; g_nstrs = 0;
    if (g_filebuf) { free(g_filebuf); g_filebuf = NULL; }
    B = NULL;
    N = 0;
    g_nclasses = 0;
    g_ncats = 0;
    g_nprotos = 0;
    g_nlinked = 0;
    g_nimports = 0;
    g_nimps = 0;
    g_nsyms = 0;
    g_image_base = 0;
    g_filesize = 0;
    g_opt_maxstrs = 20000;
    g_opt_minlen = 4;
    g_opt_xrefs = 1;
    g_arch_name = "unknown";
    g_filetype_name = "unknown";
    g_platform_name = "unknown";
    arena_reset();
}

static int engine_alloc(void) {
    g_segs = (Seg *)calloc(MAX_SEGMENTS, sizeof(Seg));
    g_sects = (Sect *)calloc(MAX_SECTIONS, sizeof(Sect));
    g_fix = (Fix *)calloc(MAX_FIXUPS, sizeof(Fix));
    g_fstart = (u64 *)calloc(MAX_FUNCS, sizeof(u64));
    g_stubs = (Stub *)calloc(MAX_STUBS, sizeof(Stub));
    g_calls = (CallRec *)calloc(MAX_CALLS, sizeof(CallRec));
    int ns = g_opt_maxstrs > 0 ? g_opt_maxstrs : 1;
    if (ns > MAX_STRINGS) ns = MAX_STRINGS;
    g_strs = (StrEnt *)calloc((size_t)ns, sizeof(StrEnt));
    if (!g_segs || !g_sects || !g_fix || !g_fstart || !g_stubs || !g_calls || !g_strs) return 0;
    return 1;
}

// options: "max_strings=N;min_len=N;xrefs=0"
static void parse_options(const char *o) {
    if (!o) return;
    const char *p = o;
    while (*p) {
        while (*p == ';' || *p == ' ' || *p == ',') p++;
        if (!*p) break;
        const char *k = p;
        while (*p && *p != '=' && *p != ';') p++;
        size_t klen = (size_t)(p - k);
        long v = 0;
        if (*p == '=') {
            p++;
            v = strtol(p, NULL, 10);
            while (*p && *p != ';') p++;
        }
        if (klen == 11 && !strncmp(k, "max_strings", 11)) {
            if (v > 0) g_opt_maxstrs = (int)(v > MAX_STRINGS ? MAX_STRINGS : v);
        } else if (klen == 7 && !strncmp(k, "min_len", 7)) {
            if (v >= 1) g_opt_minlen = (int)(v > 512 ? 512 : v);
        } else if (klen == 5 && !strncmp(k, "xrefs", 5)) {
            g_opt_xrefs = v ? 1 : 0;
        }
    }
}

static int read_whole(const char *path, char *err, size_t ec) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        snprintf(err, ec, "无法打开文件");
        return -1;
    }
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        snprintf(err, ec, "无法定位文件末尾");
        return -1;
    }
    long sz = ftell(f);
    if (sz <= 0) {
        fclose(f);
        snprintf(err, ec, "文件为空");
        return -1;
    }
    if (sz > (long)(1024LL * 1024 * 1024)) {
        fclose(f);
        snprintf(err, ec, "文件超过 1GB，已拒绝");
        return -1;
    }
    rewind(f);
    u8 *buf = (u8 *)malloc((size_t)sz);
    if (!buf) {
        fclose(f);
        snprintf(err, ec, "内存不足（需要 %ld 字节）", sz);
        return -1;
    }
    size_t got = fread(buf, 1, (size_t)sz, f);
    fclose(f);
    if (got != (size_t)sz) {
        free(buf);
        snprintf(err, ec, "读取不完整");
        return -1;
    }
    g_filebuf = buf;
    g_filesize = (size_t)sz;
    return 0;
}

static u64 be64(size_t o) {
    if (o + 8 > N) return 0;
    u64 v = 0;
    for (int i = 0; i < 8; i++) v = (v << 8) | (u64)B[o + i];
    return v;
}

// fat 头里挑一个切片：优先 arm64e，其次 arm64
static int pick_slice(size_t *off, size_t *len, char *err, size_t ec) {
    *off = 0;
    *len = N;
    if (N < 8) return 0;
    u32 m = be32(0);
    if (m != 0xCAFEBABE && m != 0xCAFEBABF) return 0;
    int fat64 = (m == 0xCAFEBABF);
    u32 n = be32(4);
    if (n == 0 || n > 32) {
        snprintf(err, ec, "fat 头架构数量异常（%u）", n);
        return -1;
    }
    size_t entsz = fat64 ? 32 : 20;
    int best = -1;
    u64 best_off = 0, best_len = 0;
    int best_rank = -1;
    for (u32 i = 0; i < n; i++) {
        size_t e = 8 + (size_t)i * entsz;
        if (e + entsz > N) break;
        u32 ct = be32(e);
        u32 cs = be32(e + 4);
        u64 o = fat64 ? be64(e + 8) : (u64)be32(e + 8);
        u64 l = fat64 ? be64(e + 16) : (u64)be32(e + 12);
        int rank = 0;
        if (ct == 0x0100000C) rank = ((cs & 0x00FFFFFFu) == 2) ? 3 : 2;
        else if (ct == 0x0000000C) rank = 1;
        if (rank > best_rank) {
            best_rank = rank;
            best = (int)i;
            best_off = o;
            best_len = l;
        }
    }
    if (best < 0 || best_len < 32 || best_off + best_len > N) {
        snprintf(err, ec, "fat 切片越界或为空");
        return -1;
    }
    *off = (size_t)best_off;
    *len = (size_t)best_len;
    return 0;
}

// 没有 LC_FUNCTION_STARTS 时，用 __text 起点 + 方法实现 + stub 兜底
static int u64_cmp(const void *a, const void *b) {
    u64 x = *(const u64 *)a, y = *(const u64 *)b;
    return x < y ? -1 : (x > y ? 1 : 0);
}
static void ensure_fstarts(void) {
    if (g_nfstart > 0) return;
    int cap = MAX_FUNCS;
    int n = 0;
    const Sect *t = sect_by_name("__TEXT", "__text");
    if (t && n < cap) g_fstart[n++] = t->addr;
    for (int i = 0; i < g_nclasses; i++) {
        for (int k = 0; k < g_classes[i].nmeth + g_classes[i].ncls && n < cap; k++) {
            const Method *m = k < g_classes[i].nmeth ? &g_classes[i].meth[k] : &g_classes[i].clsm[k - g_classes[i].nmeth];
            if (m->imp) g_fstart[n++] = m->imp;
        }
    }
    for (int i = 0; i < g_ncats; i++) {
        for (int k = 0; k < g_cats[i].ncatmeth + g_cats[i].ncls && n < cap; k++) {
            const Method *m = k < g_cats[i].ncatmeth ? &g_cats[i].catmeth[k] : &g_cats[i].clsm[k - g_cats[i].ncatmeth];
            if (m->imp) g_fstart[n++] = m->imp;
        }
    }
    for (int i = 0; i < g_nstubs && n < cap; i++) g_fstart[n++] = g_stubs[i].va;
    if (n <= 0) return;
    qsort(g_fstart, (size_t)n, sizeof(u64), u64_cmp);
    int w = 1;
    for (int i = 1; i < n; i++)
        if (g_fstart[i] != g_fstart[w - 1]) g_fstart[w++] = g_fstart[i];
    g_nfstart = w;
}

static int write_out(const char *dir, const char *name, const char *buf, size_t n, char *err, size_t ec) {
    char path[1200];
    snprintf(path, sizeof(path), "%s/%s", dir, name);
    FILE *f = fopen(path, "wb");
    if (!f) {
        snprintf(err, ec, "无法写入 %s", path);
        return -1;
    }
    size_t w = fwrite(buf, 1, n, f);
    if (fclose(f) != 0 || w != n) {
        snprintf(err, ec, "写入 %s 不完整", path);
        return -1;
    }
    return 0;
}

// 装载 + 解析 + 收集（两个入口共用）
static int prepare(const char *file_path, char *err, size_t ec) {
    if (read_whole(file_path, err, ec)) return -1;
    B = g_filebuf;
    N = g_filesize;
    if (!engine_alloc()) {
        snprintf(err, ec, "内存不足（解析表分配失败）");
        return -1;
    }
    size_t off = 0, len = 0;
    if (pick_slice(&off, &len, err, ec)) return -1;
    B = g_filebuf + off;
    N = len;
    if (parse_macho(err, ec)) return -1;
    objc_collect();
    build_imps();
    collect_sect_strings("__cstring", "__cstring");
    collect_sect_strings("__objc_methname", "__objc_methname");
    collect_sect_strings("__objc_classname", "__objc_classname");
    collect_sect_strings("__objc_methtype", "__objc_methtype");
    collect_sect_strings("__objc_propname", "__objc_propname");
    collect_cfstrings();
    if (g_nstrs > 1) qsort(g_strs, (size_t)g_nstrs, sizeof(StrEnt), str_cmp);
    scan_stubs();
    if (g_nstubs > 1) {
        for (int i = 1; i < g_nstubs; i++) {
            Stub t = g_stubs[i];
            int j = i - 1;
            while (j >= 0 && g_stubs[j].va > t.va) { g_stubs[j + 1] = g_stubs[j]; j--; }
            g_stubs[j + 1] = t;
        }
    }
    ensure_fstarts();
    scan_text();
    finish_calls();
    collect_imports();
    return 0;
}

const char *xosvi_re_version(void) { return XRE_VERSION; }

int xosvi_re_analyze(const char *file_path, const char *out_dir, const char *options,
                     char *err, size_t err_cap) {
    char dummy[8];
    if (!err) { err = dummy; err_cap = sizeof(dummy); }
    if (err_cap) err[0] = 0;
    if (!file_path || !*file_path) {
        snprintf(err, err_cap, "缺少文件路径");
        return -1;
    }
    if (!out_dir || !*out_dir) {
        snprintf(err, err_cap, "缺少输出目录");
        return -1;
    }
    engine_free();
    parse_options(options);
    int rc = -1;
    if (prepare(file_path, err, err_cap)) goto done;

    SB jb, mb;
    sb_init(&jb);
    sb_init(&mb);
    if (!jb.p || !mb.p) {
        snprintf(err, err_cap, "内存不足（报告缓冲分配失败）");
        free(jb.p);
        free(mb.p);
        goto done;
    }
    j_header(&jb, file_path);
    j_linked(&jb);
    j_sections(&jb);
    j_classes(&jb);
    j_categories(&jb);
    j_protocols(&jb);
    j_strings(&jb);
    j_functions(&jb);
    sb_puts(&jb, "\n}\n");
    md_report(&mb, file_path);

    if (write_out(out_dir, "report.json", jb.p, jb.n, err, err_cap) == 0 &&
        write_out(out_dir, "report.md", mb.p, mb.n, err, err_cap) == 0)
        rc = 0;
    free(jb.p);
    free(mb.p);
done:
    engine_free();
    return rc;
}

int xosvi_re_strings(const char *file_path, const char *query, const char *out_dir,
                     char *err, size_t err_cap) {
    char dummy[8];
    if (!err) { err = dummy; err_cap = sizeof(dummy); }
    if (err_cap) err[0] = 0;
    if (!file_path || !*file_path || !out_dir || !*out_dir) {
        snprintf(err, err_cap, "缺少文件路径或输出目录");
        return -1;
    }
    engine_free();
    g_opt_xrefs = 0;
    int rc = -1;
    if (prepare(file_path, err, err_cap)) goto done;
    SB b;
    sb_init(&b);
    if (!b.p) {
        snprintf(err, err_cap, "内存不足（缓冲分配失败）");
        goto done;
    }
    sb_puts(&b, "{\n\"engine\":");
    sb_jstr(&b, "xosvi-re " XRE_VERSION);
    sb_puts(&b, ",\n\"file\":");
    sb_jstr(&b, file_path);
    sb_puts(&b, ",\n\"query\":");
    sb_jstr(&b, query ? query : "");
    sb_puts(&b, ",\n\"total\":");
    char t[32];
    int hit = 0;
    for (int i = 0; i < g_nstrs; i++) {
        if (query && *query) {
            if (!ci_has(g_strs[i].s, query)) continue;
            hit++;
        }
    }
    if (!query || !*query) hit = g_nstrs;
    snprintf(t, sizeof(t), "%d", hit);
    sb_puts(&b, t);
    sb_puts(&b, ",\n\"strings\":[");
    int first = 1;
    for (int i = 0; i < g_nstrs; i++) {
        StrEnt *s = &g_strs[i];
        if (query && *query && !ci_has(s->s, query)) continue;
        if (!first) sb_add(&b, ",", 1);
        first = 0;
        sb_puts(&b, "\n{\"addr\":");
        j_addr(&b, s->va);
        sb_puts(&b, ",\"section\":");
        sb_jstr(&b, s->tag);
        sb_puts(&b, ",\"value\":");
        sb_jstr(&b, s->s);
        const char *kw = keyword_tag(s->s);
        if (kw) {
            sb_puts(&b, ",\"tag\":");
            sb_jstr(&b, kw);
        }
        sb_add(&b, "}", 1);
    }
    sb_puts(&b, "\n]\n}\n");
    rc = write_out(out_dir, "strings.json", b.p, b.n, err, err_cap);
    free(b.p);
done:
    engine_free();
    return rc;
}

// ---------------------------------------------------------------- 本机自测入口（-DXRE_TOOL）

#ifdef XRE_TOOL
int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <macho> <out_dir> [options]\n", argv[0]);
        return 2;
    }
    char err[512];
    int rc = xosvi_re_analyze(argv[1], argv[2], argc > 3 ? argv[3] : NULL, err, sizeof(err));
    if (rc) {
        fprintf(stderr, "FAIL: %s\n", err);
        return 1;
    }
    printf("OK %s -> %s/report.json, report.md\n", argv[1], argv[2]);
    return 0;
}
#endif

