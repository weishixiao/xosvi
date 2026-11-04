// 最小 zip 解压（stored + deflate），用于解开 GitHub Actions 日志包。
#import <Foundation/Foundation.h>
#import <zlib.h>

static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t le32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 3) { fprintf(stderr, "usage: unzipmini <zip> <outdir>\n"); return 2; }
        NSData *d = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
        if (!d) { fprintf(stderr, "cannot read\n"); return 1; }
        const uint8_t *b = d.bytes; size_t n = d.length;
        NSString *out = [NSString stringWithUTF8String:argv[2]];
        [[NSFileManager defaultManager] createDirectoryAtPath:out withIntermediateDirectories:YES attributes:nil error:nil];

        long eocd = -1;
        for (long i = (long)n - 22; i >= 0 && i > (long)n - 70000; i--)
            if (le32(b + i) == 0x06054b50) { eocd = i; break; }
        if (eocd < 0) { fprintf(stderr, "no EOCD\n"); return 1; }
        uint16_t count = le16(b + eocd + 10);
        size_t pos = le32(b + eocd + 16);
        int ok = 0, fail = 0;

        for (uint16_t i = 0; i < count && pos + 46 <= n; i++) {
            if (le32(b + pos) != 0x02014b50) break;
            uint16_t method = le16(b + pos + 10);
            uint32_t csize = le32(b + pos + 20), usize = le32(b + pos + 24);
            uint16_t nlen = le16(b + pos + 28), elen = le16(b + pos + 30), clen = le16(b + pos + 32);
            uint32_t lho = le32(b + pos + 42);
            NSString *name = [[NSString alloc] initWithBytes:b + pos + 46 length:nlen encoding:NSUTF8StringEncoding];
            pos += 46 + nlen + elen + clen;
            if (!name.length || [name hasSuffix:@"/"]) continue;
            if (lho + 30 > n || le32(b + lho) != 0x04034b50) { fail++; continue; }
            size_t dataOff = lho + 30 + le16(b + lho + 26) + le16(b + lho + 28);
            if (dataOff + csize > n) { fail++; continue; }
            NSData *payload = nil;
            if (method == 0) {
                payload = [NSData dataWithBytes:b + dataOff length:csize];
            } else if (method == 8) {
                NSMutableData *m = [NSMutableData dataWithLength:usize ? usize : 1024];
                z_stream zs; memset(&zs, 0, sizeof zs);
                if (inflateInit2(&zs, -MAX_WBITS) != Z_OK) { fail++; continue; }
                zs.next_in = (Bytef *)(b + dataOff); zs.avail_in = csize;
                zs.next_out = m.mutableBytes; zs.avail_out = (uInt)m.length;
                int r = inflate(&zs, Z_FINISH);
                size_t produced = m.length - zs.avail_out;
                inflateEnd(&zs);
                if (r != Z_STREAM_END && r != Z_OK && r != Z_BUF_ERROR) { fail++; continue; }
                m.length = produced;
                payload = m;
            } else { fail++; continue; }
            NSString *plain = [name stringByReplacingOccurrencesOfString:@"/" withString:@"__"];
            if ([payload writeToFile:[out stringByAppendingPathComponent:plain] atomically:YES]) ok++; else fail++;
        }
        fprintf(stderr, "entries=%d ok=%d fail=%d\n", count, ok, fail);
        return 0;
    }
}
