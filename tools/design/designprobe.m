// designprobe —— 把一张设计图「读成文字」：OCR 文本行 + 配色 + 行带结构
//
// 用途：本会话的模型看不了图片，只能用程序把设计图里的可测特征抽出来：
//   * 每个文字行的位置、行高（像素与 pt）、识别结果；
//   * 全图主色（背景/卡片/文字/强调色）占比；
//   * 逐行的「非背景像素」计数，合并成行带 → 行距、分组边界；
//   * 一张 64 列的灰度字符画，能看出卡片、圆角、分区的粗略形状。
// 只读，不改任何文件。用法: designprobe <image> [--noocr]

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Vision/Vision.h>

static unsigned char *g_pix;
static size_t g_w, g_h, g_stride;

static inline int dist(const unsigned char *p, int r, int g, int b) {
    return abs((int)p[0] - r) + abs((int)p[1] - g) + abs((int)p[2] - b);
}

typedef struct { int key, count; } ColorCount;

static int cmp_color(const void *a, const void *b) {
    return ((const ColorCount *)b)->count - ((const ColorCount *)a)->count;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: designprobe <image> [--noocr]\n"); return 2; }
        BOOL noocr = (argc > 2 && strcmp(argv[2], "--noocr") == 0);

        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
        CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
        if (!src) { printf("cannot open %s\n", argv[1]); return 1; }
        CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
        if (!img) { printf("cannot decode %s\n", argv[1]); return 1; }

        g_w = CGImageGetWidth(img);
        g_h = CGImageGetHeight(img);
        g_stride = g_w * 4;
        g_pix = calloc(g_h, g_stride);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(g_pix, g_w, g_h, 8, g_stride, cs,
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
        CGContextFillRect(ctx, CGRectMake(0, 0, g_w, g_h));
        CGContextDrawImage(ctx, CGRectMake(0, 0, g_w, g_h), img);
        CGContextRelease(ctx); CGColorSpaceRelease(cs);

        printf("image: %zux%zu px  (~%.0f x %.0f pt @3x)\n", g_w, g_h, g_w / 3.0, g_h / 3.0);

        /* ---- 主色统计（每通道 5 bit） ---- */
        int colorCount = 1 << 15;
        int *hist = calloc(colorCount, sizeof(int));
        for (size_t y = 0; y < g_h; y++) {
            unsigned char *row = g_pix + y * g_stride;
            for (size_t x = 0; x < g_w; x++) {
                unsigned char *p = row + x * 4;
                hist[((p[0] >> 3) << 10) | ((p[1] >> 3) << 5) | (p[2] >> 3)]++;
            }
        }
        ColorCount *cc = calloc(colorCount, sizeof(ColorCount));
        int nz = 0;
        for (int i = 0; i < colorCount; i++)
            if (hist[i]) { cc[nz].key = i; cc[nz].count = hist[i]; nz++; }
        qsort(cc, nz, sizeof(ColorCount), cmp_color);

        int bgR = ((cc[0].key >> 10) & 31) << 3;
        int bgG = ((cc[0].key >> 5) & 31) << 3;
        int bgB = (cc[0].key & 31) << 3;
        printf("\n== palette (top %d, background = #%02x%02x%02x) ==\n",
               nz < 12 ? nz : 12, bgR, bgG, bgB);
        double total = (double)g_w * (double)g_h;
        for (int i = 0; i < nz && i < 12; i++) {
            int r = ((cc[i].key >> 10) & 31) << 3, g = ((cc[i].key >> 5) & 31) << 3, b = (cc[i].key & 31) << 3;
            printf("  #%02x%02x%02x  %5.2f%%\n", r, g, b, 100.0 * cc[i].count / total);
        }

        /* ---- 逐行墨量 → 行带 ---- */
        int *ink = calloc(g_h, sizeof(size_t));
        for (size_t y = 0; y < g_h; y++) {
            unsigned char *row = g_pix + y * g_stride;
            int c = 0;
            for (size_t x = 0; x < g_w; x++) {
                unsigned char *p = row + x * 4;
                if (dist(p, bgR, bgG, bgB) > 24) c++;
            }
            ink[y] = c;
        }
        int thr = (int)(g_w * 0.004);
        printf("\n== row bands (threshold %d px of %zu) ==\n", thr, g_w);
        size_t y = 0;
        while (y < g_h) {
            if (ink[y] <= thr) { y++; continue; }
            size_t y0 = y, gap = 0;
            while (y < g_h) {
                if (ink[y] <= thr) { gap++; if (gap > 3) break; } else gap = 0;
                y++;
            }
            size_t y1 = (y > gap) ? y - gap - 1 : y - 1;
            /* 带内统计：x 范围、墨量峰值、墨色中位数 */
            size_t xmin = g_w, xmax = 0;
            int peak = 0;
            int histLum[256] = {0};
            long sr = 0, sg = 0, sb = 0, sn = 0;
            for (size_t yy = y0; yy <= y1; yy++) {
                if (ink[yy] > peak) peak = ink[yy];
                if (ink[yy] <= thr) continue;
                unsigned char *row = g_pix + yy * g_stride;
                for (size_t x = 0; x < g_w; x++) {
                    unsigned char *p = row + x * 4;
                    if (dist(p, bgR, bgG, bgB) <= 24) continue;
                    if (x < xmin) xmin = x;
                    if (x > xmax) xmax = x;
                    int lum = (p[0] * 30 + p[1] * 59 + p[2] * 11) / 100;
                    histLum[lum]++;
                    sr += p[0]; sg += p[1]; sb += p[2]; sn++;
                }
            }
            int med = 0, acc = 0;
            long half = sn / 2;
            for (int l = 0; l < 256; l++) { acc += histLum[l]; if (acc >= half) { med = l; break; } }
            printf("  y %4zu-%4zu  h=%3zu px (%5.1f pt)  x %3zu-%4zu  peak=%3d(%4.1f%%)  medLum=%3d mean=#%02lx%02lx%02lx\n",
                   y0, y1, y1 - y0 + 1, (y1 - y0 + 1) / 3.0, xmin, xmax, peak, 100.0 * peak / g_w, med,
                   sn ? sr / sn : 0, sn ? sg / sn : 0, sn ? sb / sn : 0);
        }

        /* ---- 大面积填充带（卡片/分区底色） ---- */
        printf("\n== fill bands (>45%% one color) ==\n");
        {
            size_t yy = 0;
            while (yy < g_h) {
                /* 该行最多的单一颜色 */
                int *h2 = calloc(colorCount, sizeof(int));
                unsigned char *row = g_pix + yy * g_stride;
                for (size_t x = 0; x < g_w; x++) {
                    unsigned char *p = row + x * 4;
                    h2[((p[0] >> 3) << 10) | ((p[1] >> 3) << 5) | (p[2] >> 3)]++;
                }
                int best = 0, bestK = 0;
                for (int i = 0; i < colorCount; i++) if (h2[i] > best) { best = h2[i]; bestK = i; }
                free(h2);
                if (best > g_w * 45 / 100 && !(bestK == cc[0].key)) {
                    size_t y0 = yy, y1 = yy;
                    while (y1 + 1 < g_h) {
                        int *h3 = calloc(colorCount, sizeof(int));
                        unsigned char *r2 = g_pix + (y1 + 1) * g_stride;
                        for (size_t x = 0; x < g_w; x++) {
                            unsigned char *p = r2 + x * 4;
                            h3[((p[0] >> 3) << 10) | ((p[1] >> 3) << 5) | (p[2] >> 3)]++;
                        }
                        int b2 = 0, b2k = 0;
                        for (int i = 0; i < colorCount; i++) if (h3[i] > b2) { b2 = h3[i]; b2k = i; }
                        free(h3);
                        if (b2 > g_w * 45 / 100 && b2k == bestK) y1++; else break;
                    }
                    int r = ((bestK >> 10) & 31) << 3, g = ((bestK >> 5) & 31) << 3, b = (bestK & 31) << 3;
                    printf("  y %4zu-%4zu h=%3zu px  color=#%02x%02x%02x\n", y0, y1, y1 - y0 + 1, r, g, b);
                    yy = y1 + 1;
                } else yy++;
            }
        }

        /* ---- 字符画 ---- */
        {
            int cols = 64;
            int cell = (int)(g_w < (size_t)cols ? 1 : g_w / cols);
            int rows = (int)(g_h / cell);
            printf("\n== ascii map (%d cols, 1 char = %d px = %.0f pt) ==\n", cols, cell, cell / 3.0);
            for (int ry = 0; ry < rows; ry++) {
                char line[128];
                for (int rx = 0; rx < cols; rx++) {
                    long sr = 0, sg = 0, sb = 0; int n = 0;
                    for (int yy = ry * cell; yy < (ry + 1) * cell && yy < (int)g_h; yy++) {
                        unsigned char *row = g_pix + yy * g_stride;
                        for (int xx = rx * cell; xx < (rx + 1) * cell && xx < (int)g_w; xx++) {
                            unsigned char *p = row + xx * 4;
                            sr += p[0]; sg += p[1]; sb += p[2]; n++;
                        }
                    }
                    if (!n) { line[rx] = ' '; continue; }
                    int r = (int)(sr / n), g = (int)(sg / n), b = (int)(sb / n);
                    int d = abs(r - bgR) + abs(g - bgG) + abs(b - bgB);
                    int lum = (r * 30 + g * 59 + b * 11) / 100;
                    char c = ' ';
                    if (d > 24) {
                        if (lum > 220) c = '.';
                        else if (lum > 180) c = ':';
                        else if (lum > 140) c = '-';
                        else if (lum > 100) c = '+';
                        else if (lum > 60) c = '*';
                        else if (lum > 30) c = '#';
                        else c = '@';
                    }
                    line[rx] = c;
                }
                line[cols] = '\0';
                printf("%4d |%s|\n", ry * cell, line);
            }
        }

        /* ---- 指定矩形内的墨迹包围盒（--box=x0,y0,x1,y1） ---- */
        if (argc > 2 && strncmp(argv[2], "--box=", 6) == 0) {
            int x0 = 0, y0 = 0, x1 = 0, y1 = 0;
            if (sscanf(argv[2] + 6, "%d,%d,%d,%d", &x0, &y0, &x1, &y1) == 4) {
                if (x1 > (int)g_w) x1 = (int)g_w;
                if (y1 > (int)g_h) y1 = (int)g_h;
                int minx = x1, maxx = -1, miny = y1, maxy = -1, n = 0;
                long sr = 0, sg = 0, sb = 0;
                for (int yy = y0; yy < y1; yy++) {
                    unsigned char *row = g_pix + (size_t)yy * g_stride;
                    for (int xx = x0; xx < x1; xx++) {
                        unsigned char *p = row + (size_t)xx * 4;
                        /* 任一通道比背景暗/亮超过 60 才算墨迹，避开 JPEG 噪声 */
                        int d = abs((int)p[0] - bgR) + abs((int)p[1] - bgG) + abs((int)p[2] - bgB);
                        if (d <= 90) continue;
                        if (xx < minx) minx = xx;
                        if (xx > maxx) maxx = xx;
                        if (yy < miny) miny = yy;
                        if (yy > maxy) maxy = yy;
                        n++; sr += p[0]; sg += p[1]; sb += p[2];
                    }
                }
                if (n == 0) printf("\n== box %d,%d,%d,%d: empty ==\n", x0, y0, x1, y1);
                else
                    printf("\n== box %d,%d,%d,%d: ink x %d-%d y %d-%d (h=%d px = %.2f pt, w=%d px), mean #%02lx%02lx%02lx, %d px ==\n",
                           x0, y0, x1, y1, minx, maxx, miny, maxy, maxy - miny + 1, (maxy - miny + 1) / 3.0,
                           maxx - minx + 1, sr / n, sg / n, sb / n, n);
            }
            printf("\ndone\n");
            return 0;
        }

        /* ---- 指定行的颜色游程（--scan y1,y2 或 --vscan x1,x2） ---- */
        if (argc > 2 && (strncmp(argv[2], "--scan=", 7) == 0 || strncmp(argv[2], "--vscan=", 8) == 0)) {
            BOOL vertical = (argv[2][2] == 'v');
            const char *list = argv[2] + (vertical ? 8 : 7);
            char tmp[512];
            snprintf(tmp, sizeof tmp, "%s", list);
            printf("\n== %s ==\n", vertical ? "vertical runs" : "horizontal runs");
            char *save = NULL;
            for (char *tok = strtok_r(tmp, ",", &save); tok; tok = strtok_r(NULL, ",", &save)) {
                long v = strtol(tok, NULL, 10);
                long limit = vertical ? (long)g_h : (long)g_w;
                if (v < 0 || v >= limit) continue;
                printf(" %s %ld:\n", vertical ? "x" : "y", v);
                long start = 0;
                int pr = -1, pg = -1, pb = -1;
                for (long i = 0; i <= limit; i++) {
                    int r = 0, g = 0, b = 0;
                    if (i < limit) {
                        unsigned char *p = vertical ? (g_pix + i * g_stride + (size_t)v * 4)
                                                    : (g_pix + (size_t)v * g_stride + i * 4);
                        r = p[0]; g = p[1]; b = p[2];
                    }
                    if (i == 0) { pr = r; pg = g; pb = b; start = 0; continue; }
                    if (i < limit && abs(r - pr) <= 6 && abs(g - pg) <= 6 && abs(b - pb) <= 6) continue;
                    if (i - start >= 2 || i == limit)
                        printf("   %4ld-%4ld (%3ld px)  #%02x%02x%02x\n", start, i - 1, i - start, pr, pg, pb);
                    start = i; pr = r; pg = g; pb = b;
                }
            }
            printf("\ndone\n");
            return 0;
        }

        /* ---- OCR ---- */
        if (!noocr) {
            printf("\n== ocr ==\n");
            VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:img options:@{}];
            VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] init];
            req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
            req.recognitionLanguages = @[ @"zh-Hans", @"en-US" ];
            req.usesLanguageCorrection = YES;
            NSError *err = nil;
            if (![handler performRequests:@[ req ] error:&err]) {
                printf("  failed: %s\n", err.localizedDescription.UTF8String);
            } else {
                NSArray *res = req.results;
                NSArray *sorted = [res sortedArrayUsingComparator:^NSComparisonResult(VNRecognizedTextObservation *a, VNRecognizedTextObservation *b) {
                    CGFloat ay = 1.0 - a.boundingBox.origin.y - a.boundingBox.size.height;
                    CGFloat by = 1.0 - b.boundingBox.origin.y - b.boundingBox.size.height;
                    if (fabs(ay - by) > 0.01) return ay < by ? NSOrderedAscending : NSOrderedDescending;
                    return a.boundingBox.origin.x < b.boundingBox.origin.x ? NSOrderedAscending : NSOrderedDescending;
                }];
                for (VNRecognizedTextObservation *o in sorted) {
                    VNRecognizedText *t = [[o topCandidates:1] firstObject];
                    CGRect b = o.boundingBox;
                    double x0 = b.origin.x * g_w, y0 = (1.0 - b.origin.y - b.size.height) * g_h;
                    double bw = b.size.width * g_w, bh = b.size.height * g_h;
                    printf("  [x=%4.0f y=%4.0f w=%4.0f h=%3.0f | pt y=%5.1f h=%4.1f] %s\n",
                           x0, y0, bw, bh, y0 / 3.0, bh / 3.0, t.string.UTF8String);
                }
            }
        }
        printf("\ndone\n");
    }
    return 0;
}
