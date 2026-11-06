// Host-only check that function constants survive the bridge (mclbridge.m decObj "fcv"). A kernel writes its
// constants to a buffer; the old encoding (MTLFunctionConstantValues sent as an empty descriptor) leaves them
// undefined, the new one must deliver them. guestEncode copies encodeConstants/constantSize from mclmetal.m
// (that file is arm64-only), so it checks Metal's enumerators and the wire format, not the shim's build.
// Run from gpu/:
//   clang -arch x86_64 -fobjc-arc -framework Foundation -framework Metal -framework IOSurface -framework CoreGraphics -framework ImageIO tests-ios/fconst-test.m -o out-ios6/fconst-test && out-ios6/fconst-test
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

static NSUInteger constantSize(NSUInteger t) {
    static const NSUInteger n[4] = {1, 2, 4, 4};
    if (t >= 3 && t <= 6) return 4 * n[t - 3];
    if (t >= 16 && t <= 19) return 2 * n[t - 16];
    if (t >= 29 && t <= 36) return 4 * n[(t - 29) % 4];
    if (t >= 37 && t <= 44) return 2 * n[(t - 37) % 4];
    if (t >= 45 && t <= 56) return n[(t - 45) % 4];
    if (t >= 81 && t <= 88) return 8 * n[(t - 81) % 4];
    if (t >= 121 && t <= 124) return 2 * n[t - 121];
    return 0;
}
static id guestEncode(id o) {
    NSMutableArray *a = [NSMutableArray array];
    const char *lists[2] = {"newIndexedConstantArray", "newNamedConstantArray"};
    for (int k = 0; k < 2; k++) {
        NSArray *vals = ((id(*)(id, SEL))objc_msgSend)(o, sel_registerName(lists[k]));
        for (id v in vals) {
            NSUInteger t = ((NSUInteger(*)(id, SEL))objc_msgSend)(v, sel_registerName("dataType"));
            const void *p = ((const void *(*)(id, SEL))objc_msgSend)(v, sel_registerName("data"));
            id key = k == 0 ? (id)@(((NSUInteger(*)(id, SEL))objc_msgSend)(v, sel_registerName("index")))
                            : ((id(*)(id, SEL))objc_msgSend)(v, sel_registerName("name"));
            [a addObject:@[key, @(t), [NSData dataWithBytes:p length:constantSize(t)]]];
        }
    }
    return @{@"fcv": a};
}

static void run(id dev, id lib, id fcvArg, uint32_t out[4]) {
    NSDictionary *fn = rpc(@{@"c": @"msg", @"h": lib, @"sel": @"newFunctionWithName:constantValues:error:", @"args": @[@"kfc", fcvArg, @{@"outerr": @YES}]});
    CHECK(fn[@"r"][@"h"]);
    id ps = rpc(@{@"c": @"msg", @"h": dev, @"sel": @"newComputePipelineStateWithFunction:error:", @"args": @[fn[@"r"], @{@"outerr": @YES}]})[@"r"][@"h"];
    id buf = rpc(@{@"c": @"msg", @"h": dev, @"sel": @"newBufferWithLength:options:", @"args": @[q(16), q(MTLResourceStorageModeShared)]})[@"r"][@"h"];
    id queue = rpc(@{@"c": @"msg", @"h": dev, @"sel": @"newCommandQueue", @"args": @[]})[@"r"][@"h"];
    id cb = rpc(@{@"c": @"msg", @"h": queue, @"sel": @"commandBuffer", @"args": @[]})[@"r"][@"h"];
    id enc = rpc(@{@"c": @"msg", @"h": cb, @"sel": @"computeCommandEncoder", @"args": @[]})[@"r"][@"h"];
    CHECK(ps && buf && enc);
    MTLSize one = {1, 1, 1};
    NSData *s1 = [NSData dataWithBytes:&one length:sizeof one];
    rpc(@{@"c": @"msg", @"h": enc, @"sel": @"setComputePipelineState:", @"args": @[@{@"h": ps}]});
    rpc(@{@"c": @"msg", @"h": enc, @"sel": @"setBuffer:offset:atIndex:", @"args": @[@{@"h": buf}, q(0), q(0)]});
    rpc(@{@"c": @"msg", @"h": enc, @"sel": @"dispatchThreads:threadsPerThreadgroup:", @"args": @[s1, s1]});
    rpc(@{@"c": @"msg", @"h": enc, @"sel": @"endEncoding", @"args": @[]});
    rpc(@{@"c": @"msg", @"h": cb, @"sel": @"commit", @"args": @[]});
    rpc(@{@"c": @"msg", @"h": cb, @"sel": @"waitUntilCompleted", @"args": @[]});
    memcpy(out, [(id<MTLBuffer>)objFor(buf) contents], 16);
}

int main(void) {
    @autoreleasepool {
        ensureInit();
        id dev = rpc(@{@"c": @"root", @"what": @"device"})[@"r"][@"h"];
        NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "constant uint k [[function_constant(3)]];\n"
            "constant bool b [[function_constant(1)]];\n"
            "constant ushort2 v [[function_constant(10)]];\n"
            "constant float scale [[function_constant(20)]];\n"
            "kernel void kfc(device uint *o [[buffer(0)]]) {\n"
            "  o[0] = is_function_constant_defined(k) ? k : 0xdead;\n"
            "  o[1] = is_function_constant_defined(b) ? uint(b) + 100 : 0xdead;\n"
            "  o[2] = is_function_constant_defined(v) ? uint(v.x) * 1000 + v.y : 0xdead;\n"
            "  o[3] = is_function_constant_defined(scale) ? as_type<uint>(scale) : 0xdead; }\n";
        id lib = rpc(@{@"c": @"msg", @"h": dev, @"sel": @"newLibraryWithSource:options:error:", @"args": @[src, NILV(), @{@"outerr": @YES}]})[@"r"][@"h"];
        CHECK(lib);
        MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new];
        uint32_t k = 7; BOOL b = YES; uint16_t v[2] = {3, 4}; float scale = 2.5f;
        [cv setConstantValue:&k type:MTLDataTypeUInt atIndex:3];
        [cv setConstantValue:&b type:MTLDataTypeBool atIndex:1];
        [cv setConstantValue:v type:MTLDataTypeUShort2 atIndex:10];
        [cv setConstantValue:&scale type:MTLDataTypeFloat withName:@"scale"];
        uint32_t old[4], now[4];
        run(dev, lib, @{@"$d": @"MTLFunctionConstantValues", @"p": @[]}, old);   // what an empty descriptor delivered
        run(dev, lib, guestEncode(cv), now);
        printf("old encoding: %x %x %x %x\nnew encoding: %x %x %x %x\n", old[0], old[1], old[2], old[3], now[0], now[1], now[2], now[3]);
        CHECK(old[0] == 0xdead && old[3] == 0xdead);
        uint32_t fs; memcpy(&fs, &scale, 4);
        CHECK(now[0] == 7 && now[1] == 101 && now[2] == 3004 && now[3] == fs);
        printf("PASS: function constants (index, bool, ushort2, named float) reach the host\n");
    }
    return 0;
}
