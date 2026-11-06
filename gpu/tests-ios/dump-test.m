// Host-only check of the MCL_DUMP_DIR diagnostic in mclbridge.m: a red clear into an IOSurface-backed
// texture, driven through mcl_call like the guest would, must come out as surf-<id>-2.png with red pixels.
// Run from gpu/:
//   clang -arch x86_64 -fobjc-arc -framework Foundation -framework Metal -framework IOSurface -framework CoreGraphics -framework ImageIO tests-ios/dump-test.m -o out-ios5/dump-test && out-ios5/dump-test
#include "../mclbridge.m"
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)

static NSDictionary *rpc(NSDictionary *req) {
    NSData *d = [NSPropertyListSerialization dataWithPropertyList:req format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    uint64_t ol = 0;
    void *p = mcl_call(1, d.bytes, d.length, &ol);
    NSDictionary *r = [NSPropertyListSerialization propertyListWithData:[NSData dataWithBytes:p length:ol] options:0 format:NULL error:NULL];
    free(p);
    return r;
}
static NSData *q(uint64_t v) { return [NSData dataWithBytes:&v length:8]; }
static NSDictionary *prop(NSString *n, NSString *t, id v) {
    return @{@"n": n, @"g": n, @"s": [NSString stringWithFormat:@"set%@%@:", [[n substringToIndex:1] uppercaseString], [n substringFromIndex:1]], @"t": t, @"v": v};
}

int main(void) {
    @autoreleasepool {
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"mcldump-%d", getpid()]];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        setenv("MCL_DUMP_DIR", dir.UTF8String, 1);
        ensureInit();
        IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)@{(id)kIOSurfaceWidth: @64, (id)kIOSurfaceHeight: @32,
            (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA')});
        uint32_t sid = IOSurfaceGetID(surf);
        id dev = rpc(@{@"c": @"root", @"what": @"device"})[@"r"][@"h"];
        NSDictionary *td = @{@"$d": @"MTLTextureDescriptor", @"p": @[prop(@"pixelFormat", @"Q", q(MTLPixelFormatBGRA8Unorm)),
            prop(@"width", @"Q", q(64)), prop(@"height", @"Q", q(32)), prop(@"usage", @"Q", q(MTLTextureUsageRenderTarget)),
            prop(@"storageMode", @"Q", q(MTLStorageModeManaged))]};
        id tex = rpc(@{@"c": @"msg", @"h": dev, @"sel": @"newTextureWithDescriptor:iosurface:plane:", @"args": @[td, @{@"iosurf": @(sid)}, q(0)]})[@"r"][@"h"];
        id queue = rpc(@{@"c": @"msg", @"h": dev, @"sel": @"newCommandQueue", @"args": @[]})[@"r"][@"h"];
        CHECK(tex && queue);
        MTLClearColor red = {1, 0, 0, 1};
        NSDictionary *pass = @{@"$d": @"MTLRenderPassDescriptor", @"p": @[
            @{@"n": @"colorAttachments", @"g": @"colorAttachments", @"s": @"", @"t": @"@", @"v": @{@"$d": @"MTLRenderPassColorAttachmentDescriptorArray", @"a": @[
                @{@"$d": @"MTLRenderPassColorAttachmentDescriptor", @"p": @[prop(@"texture", @"@", @{@"h": tex}),
                    prop(@"loadAction", @"Q", q(MTLLoadActionClear)), prop(@"storeAction", @"Q", q(MTLStoreActionStore)),
                    prop(@"clearColor", @"{?=dddd}", [NSData dataWithBytes:&red length:sizeof red])]}]}}]};
        for (int i = 0; i < 2; i++) {
            id cb = rpc(@{@"c": @"msg", @"h": queue, @"sel": @"commandBuffer", @"args": @[]})[@"r"][@"h"];
            id enc = rpc(@{@"c": @"msg", @"h": cb, @"sel": @"renderCommandEncoderWithDescriptor:", @"args": @[pass]})[@"r"][@"h"];
            CHECK(cb && enc);
            rpc(@{@"c": @"msg", @"h": enc, @"sel": @"endEncoding", @"args": @[]});
            rpc(@{@"c": @"msg", @"h": cb, @"sel": @"commit", @"args": @[]});
            rpc(@{@"c": @"msg", @"h": cb, @"sel": @"waitUntilCompleted", @"args": @[]});
        }
        usleep(200000);   // the completion handler runs on Metal's thread
        NSString *png = [dir stringByAppendingFormat:@"/surf-%u-2.png", sid];
        CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:png], NULL);
        CGImageRef img = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
        CHECK(img && CGImageGetWidth(img) == 64 && CGImageGetHeight(img) == 32);
        uint8_t px[4] = {0};
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(px, 1, 1, 8, 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGContextDrawImage(ctx, CGRectMake(-32, -16, 64, 32), img);
        CHECK(px[0] > 240 && px[1] < 16 && px[2] < 16 && px[3] > 240);
        printf("PASS: %s is red (rgba %u,%u,%u,%u)\n", png.UTF8String, px[0], px[1], px[2], px[3]);
        [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
    }
    return 0;
}
