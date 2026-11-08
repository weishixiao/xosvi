// 画一张「会话页导航栏 改前 / 改后」对比图，输出 PNG。
// 用 CoreGraphics + CoreText，不依赖 UIKit，命令行可直接跑。
// 编译：clang -o rendernav rendernav.c -framework CoreGraphics -framework CoreText -framework ImageIO -framework CoreFoundation
// 用法：rendernav <输出.png>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <ImageIO/ImageIO.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdbool.h>

static const double W = 900, H = 720;

static CGColorRef rgb(double r, double g, double b, double a) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGFloat c[4] = { r / 255.0, g / 255.0, b / 255.0, a };
    CGColorRef col = CGColorCreate(cs, c);
    CGColorSpaceRelease(cs);
    return col;
}

static void fillRect(CGContextRef ctx, CGRect r, double radius, CGColorRef color) {
    CGPathRef p = CGPathCreateWithRoundedRect(r, radius, radius, NULL);
    CGContextAddPath(ctx, p);
    CGContextSetFillColorWithColor(ctx, color);
    CGContextFillPath(ctx);
    CGPathRelease(p);
}

static void strokeRect(CGContextRef ctx, CGRect r, double radius, double width, CGColorRef color) {
    CGPathRef p = CGPathCreateWithRoundedRect(r, radius, radius, NULL);
    CGContextAddPath(ctx, p);
    CGContextSetStrokeColorWithColor(ctx, color);
    CGContextSetLineWidth(ctx, width);
    CGContextStrokePath(ctx);
    CGPathRelease(p);
}

static void hline(CGContextRef ctx, double x1, double x2, double y, CGColorRef color) {
    CGContextSetStrokeColorWithColor(ctx, color);
    CGContextSetLineWidth(ctx, 1);
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

// x,y = 基线（左上原点坐标）。align: 0=左, 1=居中
static void drawText(CGContextRef ctx, const char *utf8, double x, double y, double size,
                     const char *fontName, CGColorRef color, int align) {
    CTLineRef line = makeLine(utf8, size, fontName);
    double w = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    double dx = (align == 1) ? -w / 2.0 : 0;

    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, x + dx, y);
    CGContextScaleCTM(ctx, 1, -1);              // 文字转回正立
    CGContextSetTextMatrix(ctx, CGAffineTransformIdentity);
    CGContextSetTextPosition(ctx, 0, 0);
    CGContextSetFillColorWithColor(ctx, color);
    CTLineDraw(line, ctx);
    CGContextRestoreGState(ctx);
    CFRelease(line);
}

static void drawChevron(CGContextRef ctx, double x, double y, double w, double h,
                        double lw, CGColorRef color) {
    CGContextBeginPath(ctx);
    CGContextMoveToPoint(ctx, x, y);
    CGContextAddLineToPoint(ctx, x + w / 2, y + h);
    CGContextAddLineToPoint(ctx, x + w, y);
    CGContextSetStrokeColorWithColor(ctx, color);
    CGContextSetLineWidth(ctx, lw);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGContextStrokePath(ctx);
}

static void dot(CGContextRef ctx, double cx, double cy, double r, CGColorRef color) {
    CGContextSetFillColorWithColor(ctx, color);
    CGContextFillEllipseInRect(ctx, CGRectMake(cx - r, cy - r, r * 2, r * 2));
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s out.png\n", argv[0]); return 2; }

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, (size_t)W, (size_t)H, 8, 0, cs,
                                             kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) { fprintf(stderr, "ctx failed\n"); return 1; }

    CGContextTranslateCTM(ctx, 0, H);
    CGContextScaleCTM(ctx, 1, -1);              // 左上原点

    CGColorRef bg      = rgb(242, 242, 247, 1);
    CGColorRef white   = rgb(255, 255, 255, 1);
    CGColorRef hair    = rgb(229, 229, 234, 1);
    CGColorRef border  = rgb(216, 216, 221, 1);
    CGColorRef ink     = rgb(17, 17, 17, 1);
    CGColorRef grey    = rgb(138, 138, 142, 1);
    CGColorRef faint   = rgb(176, 176, 181, 1);
    CGColorRef red     = rgb(224, 52, 43, 1);
    CGColorRef green   = rgb(52, 199, 89, 1);
    CGColorRef capBg   = rgb(233, 233, 237, 1);
    CGColorRef capEdge = rgb(208, 208, 214, 1);
    CGColorRef chipBg  = rgb(0, 0, 0, 0.07);

    const char *SEMI = "PingFangSC-Semibold";
    const char *MED  = "PingFangSC-Medium";
    const char *REG  = "PingFangSC-Regular";

    const double CX = W / 2.0;                  // 导航栏内容中心线

    fillRect(ctx, CGRectMake(0, 0, W, H), 0, bg);
    drawText(ctx, "会话页导航栏：改前 / 改后（手机宽度 360pt 片段，2× 放大）",
             40, 42, 22, SEMI, ink, 0);

    // ================= 改前 =================
    drawText(ctx, "改前 · Minis 三行", 40, 92, 16, REG, faint, 0);
    fillRect(ctx, CGRectMake(40, 102, 760, 118), 10, white);
    strokeRect(ctx, CGRectMake(40, 102, 760, 118), 10, 1, border);
    hline(ctx, 40, 800, 220, hair);

    drawText(ctx, "分析这个 App 的加密逻辑", CX, 136, 26, SEMI, ink, 1);

    // 第 2 行：状态点 + 模型名 + chevron
    {
        const char *m = "DeepSeek V4";
        double tw = textW(m, 24, MED);
        double total = 12 + 6 + tw + 6 + 14;
        double x0 = CX - total / 2.0;
        double cy = 174;
        dot(ctx, x0 + 6, cy, 5, green);
        drawText(ctx, m, x0 + 12 + 6, cy + 8.5, 24, MED, ink, 0);
        drawChevron(ctx, x0 + 12 + 6 + tw + 6, cy - 4, 14, 8, 2, grey);
    }

    // 第 3 行：provider · model + 思考徽章
    {
        const char *d = "deepseek · deepseek-chat";
        double tw = textW(d, 16, REG);
        double chipW = 62, chipH = 22, gap = 10;
        double x0 = CX - (tw + gap + chipW) / 2.0;
        double cy = 202;
        drawText(ctx, d, x0, cy + 5.5, 16, REG, grey, 0);
        fillRect(ctx, CGRectMake(x0 + tw + gap, cy - chipH / 2, chipW, chipH), 11, chipBg);
        drawText(ctx, "思考 中", x0 + tw + gap + chipW / 2, cy + 5.5, 15, REG, faint, 1);
    }

    drawText(ctx, "•••", 770, 174, 18, REG, grey, 1);

    drawText(ctx, "三行", 812, 150, 15, REG, red, 0);
    drawText(ctx, "重复", 812, 174, 15, REG, red, 0);
    drawText(ctx, "且挤", 812, 198, 15, REG, red, 0);

    // ================= 改后 =================
    drawText(ctx, "改后 · xosvi 两行（任务名 + 模型快切胶囊）", 40, 288, 16, REG, faint, 0);
    fillRect(ctx, CGRectMake(40, 298, 760, 118), 10, white);
    strokeRect(ctx, CGRectMake(40, 298, 760, 118), 10, 1, border);
    hline(ctx, 40, 800, 416, hair);

    drawText(ctx, "分析这个 App 的加密逻辑", CX, 330, 26, SEMI, ink, 1);

    // 胶囊：状态点 + 模型名 + 服务商·模型 + chevron
    {
        const char *m  = "DeepSeek V4";
        const char *d  = "deepseek · deepseek-chat";
        double tw1 = textW(m, 22, MED);
        double tw2 = textW(d, 15, REG);
        const double padL = 20, padR = 18, dotR = 6, gap1 = 8, gap2 = 8, gap3 = 10, chevW = 16;
        double contentW = dotR * 2 + gap1 + tw1 + gap2 + tw2 + gap3 + chevW;
        double capW = contentW + padL + padR;
        double capH = 48;
        double cy = 366;
        double x0 = CX - capW / 2.0;

        fillRect(ctx, CGRectMake(x0, cy - capH / 2, capW, capH), capH / 2, capBg);
        strokeRect(ctx, CGRectMake(x0, cy - capH / 2, capW, capH), capH / 2, 1.4, capEdge);

        double cx1 = x0 + padL + dotR;
        dot(ctx, cx1, cy, dotR, green);
        double tx1 = cx1 + dotR + gap1;
        drawText(ctx, m, tx1, cy + 7.5, 22, MED, ink, 0);
        double tx2 = tx1 + tw1 + gap2;
        drawText(ctx, d, tx2, cy + 5.5, 15, REG, grey, 0);
        drawChevron(ctx, tx2 + tw2 + gap3, cy - 4.5, chevW, 9, 2, grey);

        // 思考徽章在胶囊右侧
        double chipW = 66, chipH = 26;
        double cx = x0 + capW + 10;
        fillRect(ctx, CGRectMake(cx, cy - chipH / 2, chipW, chipH), 13, chipBg);
        drawText(ctx, "思考 中", cx + chipW / 2, cy + 5.5, 15, REG, faint, 1);
    }

    drawText(ctx, "•••", 770, 366, 18, REG, grey, 1);

    drawText(ctx, "任务", 812, 348, 15, REG, red, 0);
    drawText(ctx, "名", 812, 370, 15, REG, red, 0);
    drawText(ctx, "快切", 812, 392, 15, REG, red, 0);

    // ================= 胶囊放大 =================
    drawText(ctx, "胶囊放大", 40, 462, 16, REG, faint, 0);
    {
        const char *m = "DeepSeek V4";
        const char *d = "deepseek · chat";
        double tw1 = textW(m, 40, MED);
        double tw2 = textW(d, 26, REG);
        const double padL = 34, padR = 30, dotR = 12, gap1 = 14, gap2 = 14, gap3 = 18, chevW = 26;
        double contentW = dotR * 2 + gap1 + tw1 + gap2 + tw2 + gap3 + chevW;
        double capW = contentW + padL + padR;
        double capH = 96;
        double cy = 540;
        double x0 = 40;

        fillRect(ctx, CGRectMake(x0, cy - capH / 2, capW, capH), capH / 2, capBg);
        strokeRect(ctx, CGRectMake(x0, cy - capH / 2, capW, capH), capH / 2, 2.4, capEdge);

        double cx1 = x0 + padL + dotR;
        dot(ctx, cx1, cy, dotR, green);
        double tx1 = cx1 + dotR + gap1;
        drawText(ctx, m, tx1, cy + 14, 40, MED, ink, 0);
        double tx2 = tx1 + tw1 + gap2;
        drawText(ctx, d, tx2, cy + 9, 26, REG, grey, 0);
        drawChevron(ctx, tx2 + tw2 + gap3, cy - 7, chevW, 14, 3, grey);
    }

    // ================= 图例 =================
    drawText(ctx, "● 绿 = 已登录　黄 = 配额低　橙 = 未登录", 40, 636, 15, REG, grey, 0);
    drawText(ctx, "主字 12pt medium · 次字 10pt 灰（最宽 132pt，超出截断）", 40, 664, 15, REG, grey, 0);
    drawText(ctx, "灰底胶囊 + 0.8pt 描边 · 高 24pt（原系统 22pt）· 点击开模型选择面板", 40, 692, 15, REG, grey, 0);

    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CFStringRef path = CFStringCreateWithCString(NULL, argv[1], kCFStringEncodingUTF8);
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, path, kCFURLPOSIXPathStyle, false);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    if (!dst) { fprintf(stderr, "dest failed\n"); return 1; }
    CGImageDestinationAddImage(dst, img, NULL);
    bool ok = CGImageDestinationFinalize(dst);
    printf(ok ? "wrote %s\n" : "write failed\n", argv[1]);
    return ok ? 0 : 1;
}
