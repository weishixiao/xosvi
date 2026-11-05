// swift_braces.c — Swift 括号/结构 sanity 的本机可运行版本
//
// 本机没有 python3，scripts/check_swift_braces.py 跑不了（该脚本本身也有重复行），
// 这里用 C 实现同一目的：剥离注释与字符串之后统计 {} () [] 是否配平。
//
// 构建：clang -O1 -o swift_braces swift_braces.c
// 用法：./swift_braces <目录|文件>... [--strict]
//   --strict 时不平衡以退出码 1 结束（CI 门禁用）。
//
// 剥离规则刻意做「宽松」：宁可多剥（把字符串/插值里的括号也剥掉），也不要误报。
//   - 行注释 // … 与块注释 /* … */（Swift 允许嵌套）
//   - 普通字符串 "…"、多行字符串 """…"""、原始字符串 #"…"# / #"""…"""#
//   - 插值 \( … ) 整体跳过（里面的括号不算代码）
// 已知不识别：正则字面量 /…/、Swift 5.9 宏 #foo(...)、字符字面量。
// 所以本工具只作 sanity，不是类型检查；MISMATCH 需人工复核。
// MISMATCH 时打印首个出问题的行号，方便定位。

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

typedef struct {
    const char *s;
    long n;
    long i;
    long line;
} Cursor;

static int at(const Cursor *c, long k, char ch) {
    return c->i + k < c->n && c->s[c->i + k] == ch;
}

static int count_run(const Cursor *c, char ch) {
    int k = 0;
    while (at(c, k, ch)) k++;
    return k;
}

/* 跳过普通/原始/多行字符串，cur 指向起始引号（或 #）处 */
static void skip_string(Cursor *c) {
    int hashes = (int)count_run(c, '#');
    long start = c->i;
    c->i += hashes;
    int quote_run = (int)count_run(c, '"');
    if (quote_run < 1) { c->i = start + 1; return; }   /* 不是字符串（#foo 宏等），只跳一个字符 */
    int triple = quote_run >= 3;
    c->i += triple ? 3 : 1;

    while (c->i < c->n) {
        if (c->s[c->i] == '\n') {
            c->line++;
            if (!triple) break;                         /* 单行字符串没闭合：别吞掉整个文件 */
        }
        if (hashes > 0) {
            /* 原始字符串：# 个数对上了才算结束 */
            if (c->s[c->i] == '"' && count_run(c, '"') >= quote_run &&
                count_run(c, '"') >= (triple ? 3 : 1)) {
                int run = (int)count_run(c, '"');
                if (triple ? run >= 3 : 1) {
                    c->i += triple ? 3 : 1;
                    if ((int)count_run(c, '#') >= hashes) { c->i += hashes; break; }
                }
            }
            c->i++;
            continue;
        }
        if (c->s[c->i] == '\\') {
            /* 插值 \( … )：整段跳过，括号不算代码 */
            if (at(c, 1, '(')) {
                c->i += 2;
                int depth = 1;
                while (c->i < c->n && depth > 0) {
                    if (c->s[c->i] == '\n') c->line++;
                    if (c->s[c->i] == '"') { skip_string(c); continue; }
                    if (c->s[c->i] == '(') depth++;
                    else if (c->s[c->i] == ')') depth--;
                    c->i++;
                }
                continue;
            }
            c->i += 2;                                  /* 普通转义，连同下一个字符一起跳过 */
            continue;
        }
        if (c->s[c->i] == '"') {
            int run = (int)count_run(c, '"');
            if (triple) {
                if (run >= 3) { c->i += 3; break; }
                c->i += run;
                continue;
            }
            c->i += 1;
            break;
        }
        c->i++;
    }
}

/* 统计剥离后的括号，返回 1 表示不平衡 */
static int scan(const char *src, long n, long *out_line) {
    Cursor c = {src, n, 0, 1};
    long open_c[3] = {0, 0, 0}, close_c[3] = {0, 0, 0};
    const char *opens = "([{", *closes = ")]}";

    while (c.i < c.n) {
        char ch = c.s[c.i];
        if (ch == '\n') { c.line++; c.i++; continue; }
        if (ch == '/' && at(&c, 1, '/')) {
            while (c.i < c.n && c.s[c.i] != '\n') c.i++;
            continue;
        }
        if (ch == '/' && at(&c, 1, '*')) {
            c.i += 2;
            int depth = 1;
            while (c.i < c.n && depth > 0) {
                if (c.s[c.i] == '\n') c.line++;
                if (c.s[c.i] == '/' && at(&c, 1, '*')) { depth++; c.i += 2; continue; }
                if (c.s[c.i] == '*' && at(&c, 1, '/')) { depth--; c.i += 2; continue; }
                c.i++;
            }
            continue;
        }
        if (ch == '"' || ch == '#') { skip_string(&c); continue; }
        for (int k = 0; k < 3; k++) {
            if (ch == opens[k]) open_c[k]++;
            else if (ch == closes[k]) {
                close_c[k]++;
                if (close_c[k] > open_c[k] && out_line && *out_line == 0) *out_line = c.line;
            }
        }
        c.i++;
    }

    int bad = 0;
    for (int k = 0; k < 3; k++) {
        if (open_c[k] != close_c[k]) {
            bad = 1;
            if (out_line && *out_line == 0) *out_line = 0;   /* 只缺闭合：没有多余闭合的行号 */
        }
    }
    if (bad) {
        fprintf(stderr, "  {} %ld/%ld  () %ld/%ld  [] %ld/%ld\n",
                open_c[2], close_c[2], open_c[0], close_c[0], open_c[1], close_c[1]);
    }
    return bad;
}

static int check_path(const char *path, const char *name) {
    FILE *f = fopen(path, "rb");
    if (!f) { printf("SKIP %s (unreadable)\n", name); return 0; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz < 0) { fclose(f); printf("SKIP %s (bad size)\n", name); return 0; }
    char *src = malloc((size_t)sz + 1);
    if (!src) { fclose(f); return 0; }
    long got = (long)fread(src, 1, (size_t)sz, f);
    src[got] = 0;
    fclose(f);

    long line = 0;
    int bad = scan(src, got, &line);
    free(src);
    if (bad) {
        if (line > 0) printf("MISMATCH %s (第 %ld 行附近)\n", name, line);
        else printf("MISMATCH %s (有未闭合的括号)\n", name);
    }
    return bad;
}

static int is_swift(const char *name) {
    size_t n = strlen(name);
    return n > 6 && strcmp(name + n - 6, ".swift") == 0;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <dir|file>... [--strict]\n", argv[0]); return 2; }

    int strict = 0, files = 0, mismatches = 0;
    for (int a = 1; a < argc; a++) {
        if (strcmp(argv[a], "--strict") == 0) { strict = 1; continue; }
        const char *arg = argv[a];
        struct stat st;
        if (stat(arg, &st) != 0) { fprintf(stderr, "cannot stat %s\n", arg); mismatches++; continue; }
        if (S_ISREG(st.st_mode)) {
            files++;
            mismatches += check_path(arg, arg);
            continue;
        }
        DIR *d = opendir(arg);
        if (!d) { fprintf(stderr, "cannot open %s\n", arg); mismatches++; continue; }
        struct dirent *e;
        while ((e = readdir(d)) != NULL) {
            if (e->d_name[0] == '.' || !is_swift(e->d_name)) continue;
            char path[2048];
            snprintf(path, sizeof path, "%s/%s", arg, e->d_name);
            struct stat fs;
            if (stat(path, &fs) != 0 || !S_ISREG(fs.st_mode)) continue;
            files++;
            mismatches += check_path(path, e->d_name);
        }
        closedir(d);
    }
    printf("checked %d files, mismatches=%d\n", files, mismatches);
    if (mismatches && strict) return 1;
    printf(mismatches ? "WARN (report-only; use --strict to fail)\n" : "OK\n");
    return 0;
}
