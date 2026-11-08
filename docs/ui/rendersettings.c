// 画「设置页 改前 / 改后」对比图，输出 PNG。
// 依据：b125414 的 Sources/XosviMCP/SettingsView.swift v7.1.1
//   「彩色方块 + 白色重图标 → 黑白简洁版（裸线条图标）」，XType.rowIcon，图标宽 26pt 居中。
// 编译：clang -o rendersettings rendersettings.c -framework CoreGraphics -framework CoreText -framework ImageIO -framework CoreFoundation
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <ImageIO/ImageIO.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdbool.h>

static const double W = 860, H = 1780;
static const double PANEL_X = 60, PANEL_W = 640;

static CGColorRef rgb(double r, double g, double b, double a) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGFloat c[4] = { r / 255.0, g / 255.0, b / 255.0, a };
    CGColorRef col = CGColorCreate(cs, c);
    CGColorSpaceRelease(cs);
    return col;
}

static void fillR(CGContextRef ctx, CGRect r, double radius, CGColorRef color) {
    CGPathRef p = CGPathCreateWithRoundedRect(r, radius, radius, NULL);
    CGContextAddPath(ctx, p);
    CGContextSetFillColorWithColor(ctx, color);
    CGContextFillPath(ctx);
    CGPathRelease(p);
}

static void strokeR(CGContextRef ctx, CGRect r, double radius, double width, CGColorRef color) {
    CGPathRef p = CGPathCreateWithRoundedRect(r, radius, radius, NULL);
    CGContextAddPath(ctx, p);
    CGContextSetStrokeColorWithColor(ctx, color);
    CGContextSetLineWidth(ctx, width);
    CGContextStrokePath(ctx);
    CGPathRelease(p);
}

static void hline(CGContextRef ctx, double x1, double x2, double y, double w, CGColorRef color) {
    CGContextSetStrokeColorWithColor(ctx, color);
    CGContextSetLineWidth(ctx, w);
    CGContextBeginPath(ctx);
    CGContextMoveToPoint(ctx, x1, y);
    CGContextAddLineToPoint(ctx, x2, y);
    CGContextStrokePath(ctx);
}

static CTLineRef makeLine(const char *utf8, double size, const char *fontName) {
    CFStringRef str = CFStringCreateWithCString(NULL, utf8, kCFStringEncodingUTF8);
    CFStringRef fn = CFStringCreateWithCString(NULL, fontName, kCFStringEncodingUTF8);
    CTFontRef font = CTFontCreateWithName(fn, size, NULL);
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, (const void **)&kCTFontAttributeName,
                                               (const void **)&font, 1,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef as = CFAttributedStringCreate(NULL, str, attrs);
    CTLineRef line = CTLineCreateWithAttributedString(as);
    CFRelease(as); CFRelease(attrs); CFRelease(font); CFRelease(fn); CFRelease(str);
    return line;
}

static double textW(const char *utf8, double size, const char *fontName) {
    CTLineRef line = makeLine(utf8, size, fontName);
    double w = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    CFRelease(line);
    return w;
}

static void drawText(CGContextRef ctx, const char *utf8, double x, double y, double size,
                     const char *fontName, CGColorRef color, int align) {
    CTLineRef line = makeLine(utf8, size, fontName);
    double w = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    double dx = (align == 1) ? -w / 2.0 : ((align == 2) ? -w : 0);
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, x + dx, y);
    CGContextScaleCTM(ctx, 1, -1);
    CGContextSetTextMatrix(ctx, CGAffineTransformIdentity);
    CGContextSetTextPosition(ctx, 0, 0);
    CGContextSetFillColorWithColor(ctx, color);
    CTLineDraw(line, ctx);
    CGContextRestoreGState(ctx);
    CFRelease(line);
}

// 简笔图标：0=方框 1=圆 2=三角 3=齿轮(八角)
static void glyph(CGContextRef ctx, double cx, double cy, double s, double lw, CGColorRef color) {
    (void)s;
    CGContextSetStrokeColorWithColor(ctx, color);
    CGContextSetLineWidth(ctx, lw);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGContextBeginPath(ctx);
    CGContextAddRect(ctx, CGRectMake(cx - 6, cy - 6, 12, 12));
    CGContextStrokePath(ctx);
    CGContextSetFillColorWithColor(ctx, color);
    CGContextFillEllipseInRect(ctx, CGRectMake(cx - 2.5, cy - 2.5, 5, 5));
}

typedef struct { const char *title; double r, g, b; } Row;

static void drawPage(CGContextRef ctx, double y0, bool legacy,
                     CGColorRef ink, CGColorRef grey, CGColorRef faint,
                     CGColorRef card, CGColorRef sep, CGColorRef panelBg) {
    const char *SEMI = "PingFangSC-Semibold";
    const char *REG  = "PingFangSC-Regular";

    const double navH = 96, rowH = 88, headH = 28, gap = 36;

    // 面板背景
    fillR(ctx, CGRectMake(PANEL_X, y0, PANEL_W, navH + 16 + (headH + rowH * 3) * 2 + gap + 16), 14, panelBg);
    // 导航栏
    fillR(ctx, CGRectMake(PANEL_X, y0, PANEL_W, navH), 14, card);
    drawText(ctx, "设置", PANEL_X + PANEL_W / 2, y0 + 60, 34, SEMI, ink, 1);
    hline(ctx, PANEL_X, PANEL_X + PANEL_W, y0 + navH, 1, sep);
    drawText(ctx, "完成", PANEL_X + PANEL_W - 20, y0 + 60, 30, REG, rgb(0, 122, 255, 1), 2);

    double y = y0 + navH + 16;

    const char *heads[2] = { "LLM PROVIDERS", "AGENT RUNTIME" };
    const char *titles[2][3] = {
        { "Manage Providers", "Model Groups", "Token Usage" },
        { "Agent Tools", "Sub Agents", "Skills" },
    };
    double colors[2][3][3] = {
        { {0, 122, 255}, {175, 82, 222}, {88, 86, 214} },
        { {88, 86, 214}, {175, 82, 222}, {0, 122, 255} },
    };

    for (int gidx = 0; gidx < 2; gidx++) {
        // 组头（卡片上方灰字）
        drawText(ctx, heads[gidx], PANEL_X + 20, y + 20, 24, REG, faint, 0);
        y += headH;

        double cardH = rowH * 3;
        fillR(ctx, CGRectMake(PANEL_X, y, PANEL_W, cardH), 18, card);

        for (int i = 0; i < 3; i++) {
            double cy = y + rowH * i + rowH / 2;
            double iconCx = PANEL_X + 32 + 10.5;
            double textX = PANEL_X + 32 + 26 + 12;

            if (legacy) {
                // 彩色圆底 + 白色图标
                CGColorRef c = rgb(colors[gidx][i][0], colors[gidx][i][1], colors[gidx][i][2], 1);
                CGContextSetFillColorWithColor(ctx, c);
                CGContextFillEllipseInRect(ctx, CGRectMake(iconCx - 15, cy - 15, 30, 30));
                glyph(ctx, iconCx, cy, 12, 2.2, card);
            } else {
                // 黑白裸线条图标
                glyph(ctx, iconCx, cy, 14, 2.6, ink);
            }
            drawText(ctx, titles[gidx][i], textX, cy + 11, 31, REG, ink, 0);

            // 行分隔线
            if (i < 2) hline(ctx, PANEL_X + 32 + 26 + 12, PANEL_X + PANEL_W, y + rowH * (i + 1), 1, sep);
        }
        y += cardH + gap;
    }
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s out.png\n", argv[0]); return 2; }

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, (size_t)W, (size_t)H, 8, 0, cs,
                                             kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return 1;

    CGContextTranslateCTM(ctx, 0, H);
    CGContextScaleCTM(ctx, 1, -1);

    CGColorRef bg     = rgb(242, 242, 247, 1);
    CGColorRef white  = rgb(255, 255, 255, 1);
    CGColorRef ink    = rgb(17, 17, 17, 1);
    CGColorRef grey   = rgb(138, 138, 142, 1);
    CGColorRef faint  = rgb(142, 142, 147, 1);
    CGColorRef sep    = rgb(229, 229, 234, 1);
    CGColorRef red    = rgb(224, 52, 43, 1);
    CGColorRef green  = rgb(52, 199, 89, 1);

    const char *SEMI = "PingFangSC-Semibold";
    const char *MED  = "PingFangSC-Medium";
    const char *REG  = "PingFangSC-Regular";

    fillR(ctx, CGRectMake(0, 0, W, H), 0, bg);

    drawText(ctx, "设置页：改前 / 改后（宽 320pt 片段，2× 放大）", 60, 48, 26, SEMI, ink, 0);

    // 改前
    drawText(ctx, "改前 · Minis 彩色圆底 + 白色图标（21×21）", 60, 100, 20, REG, grey, 0);
    drawPage(ctx, 120, true, ink, grey, faint, white, sep, bg);

    // 改后
    double y2 = 120 + 96 + 16 + (28 + 88 * 3) * 2 + 36 + 16 + 70;
    drawText(ctx, "改后 · xosvi v7.1.1 黑白裸线条图标（宽 26pt 居中）", 60, y2 - 20, 20, REG, grey, 0);
    drawPage(ctx, y2, false, ink, grey, faint, white, sep, bg);

    // 右侧标注
    double ax = 740;
    drawText(ctx, "改前", ax, 300, 22, SEMI, red, 0);
    drawText(ctx, "彩色", ax, 336, 20, REG, grey, 0);
    drawText(ctx, "圆底", ax, 364, 20, REG, grey, 0);
    drawText(ctx, "白图标", ax, 392, 20, REG, grey, 0);

    drawText(ctx, "改后", ax, 1160, 22, SEMI, green, 0);
    drawText(ctx, "纯黑", ax, 1196, 20, REG, grey, 0);
    drawText(ctx, "线条", ax, 1224, 20, REG, grey, 0);
    drawText(ctx, "无底色", ax, 1252, 20, REG, grey, 0);

    // 图例
    drawText(ctx, "· 卡片仍是系统 insetGrouped 白卡，组头大写灰字", 60, H - 88, 20, REG, grey, 0);
    drawText(ctx, "· 副标题在 v7.3.0 已按用户要求删除，只留主标题", 60, H - 50, 20, REG, grey, 0);

    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CFStringRef path = CFStringCreateWithCString(NULL, argv[1], kCFStringEncodingUTF8);
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, path, kCFURLPOSIXPathStyle, false);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    if (!dst) return 1;
    CGImageDestinationAddImage(dst, img, NULL);
    bool ok = CGImageDestinationFinalize(dst);
    printf(ok ? "wrote %s\n" : "write failed\n", argv[1]);
    return ok ? 0 : 1;
}
