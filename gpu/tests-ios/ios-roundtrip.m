// Host-only check of the IOSurface handling in mclbridge.m (x86_64; the arm64e shim cannot run here).
// The guest side (decode in mclmetal.m) is emulated: IOSurfaceLookup(id), then drop the "ih" handle.
// Run from gpu/:
//   clang -arch x86_64 -fobjc-arc -framework Foundation -framework Metal -framework IOSurface tests-ios/ios-roundtrip.m -o out-ios/ios-roundtrip && out-ios/ios-roundtrip
#include "../mclbridge.m"
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)

static id rpc(NSDictionary *req) {
    NSData *d = [NSPropertyListSerialization dataWithPropertyList:req format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    uint64_t ol = 0;
    void *p = mcl_call(1, d.bytes, d.length, &ol);
    NSDictionary *r = [NSPropertyListSerialization propertyListWithData:[NSData dataWithBytes:p length:ol] options:0 format:NULL error:NULL];
    free(p);
    return r;
}

// Emulates the guest's decode(): its own reference by id, then the host's table reference is given back.
static IOSurfaceRef guestDecode(NSDictionary *v) {
    IOSurfaceRef s = IOSurfaceLookup([v[@"iosurf"] unsignedIntValue]);
    if (v[@"ih"]) dropHandle([v[@"ih"] unsignedLongLongValue], 1);
    return s;
}

int main(void) {
    @autoreleasepool {
        ensureInit();
        IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)@{(id)kIOSurfaceWidth: @64, (id)kIOSurfaceHeight: @32,
            (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA')});
        CHECK(surf);
        uint32_t sid = IOSurfaceGetID(surf);

        // 1. host -> guest: encObj sends the id and parks the surface in the handle table until the guest drops it
        NSDictionary *enc = encObj((__bridge id)surf, NO);
        NSData *pl = [NSPropertyListSerialization dataWithPropertyList:enc format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
        NSDictionary *wire = [NSPropertyListSerialization propertyListWithData:pl options:0 format:NULL error:NULL];
        CHECK([wire[@"iosurf"] unsignedIntValue] == sid && !wire[@"h"]);
        uint64_t ih = [wire[@"ih"] unsignedLongLongValue];
        CHECK(objFor(@(ih)) == (__bridge id)surf);
        IOSurfaceRef g = guestDecode(wire);
        CHECK(g && IOSurfaceGetID(g) == sid && IOSurfaceGetWidth(g) == 64 && IOSurfaceGetHeight(g) == 32);
        CHECK(objFor(@(ih)) == nil);
        CFRelease(g);

        // 2. guest -> host: decObj of the guest's {iosurf: id}
        id h = decObj(@{@"iosurf": @(sid)});
        CHECK(h && IOSurfaceGetID((__bridge IOSurfaceRef)h) == sid && IOSurfaceGetWidth((__bridge IOSurfaceRef)h) == 64);
        h = nil;

        // 3. through mcl_call: newTextureWithDescriptor:iosurface:plane: (iosurf argument), then -iosurface (^{__IOSurface} result)
        NSDictionary *dev = rpc(@{@"c": @"root", @"what": @"device"})[@"r"];
        CHECK(dev[@"h"]);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:32 mipmapped:NO];
        td.storageMode = MTLStorageModeManaged;
        NSDictionary *desc = @{@"$d": @"MTLTextureDescriptor", @"p": @[
            @{@"n": @"pixelFormat", @"g": @"pixelFormat", @"s": @"setPixelFormat:", @"t": @"Q", @"v": [NSData dataWithBytes:&(uint64_t){MTLPixelFormatBGRA8Unorm} length:8]},
            @{@"n": @"width", @"g": @"width", @"s": @"setWidth:", @"t": @"Q", @"v": [NSData dataWithBytes:&(uint64_t){64} length:8]},
            @{@"n": @"height", @"g": @"height", @"s": @"setHeight:", @"t": @"Q", @"v": [NSData dataWithBytes:&(uint64_t){32} length:8]},
            @{@"n": @"storageMode", @"g": @"storageMode", @"s": @"setStorageMode:", @"t": @"Q", @"v": [NSData dataWithBytes:&(uint64_t){MTLStorageModeManaged} length:8]}]};
        uint64_t plane = 0;
        NSDictionary *tr = rpc(@{@"c": @"msg", @"h": dev[@"h"], @"sel": @"newTextureWithDescriptor:iosurface:plane:",
                                 @"args": @[desc, @{@"iosurf": @(sid)}, [NSData dataWithBytes:&plane length:8]]});
        CHECK(!tr[@"x"] && tr[@"r"][@"h"]);
        NSDictionary *sr = rpc(@{@"c": @"msg", @"h": tr[@"r"][@"h"], @"sel": @"iosurface", @"args": @[]});
        CHECK(!sr[@"x"] && [sr[@"r"][@"iosurf"] unsignedIntValue] == sid);
        g = guestDecode(sr[@"r"]);
        CHECK(g && IOSurfaceGetWidth(g) == 64);
        CFRelease(g);

        // 4. same getter through the binary fast path (execCall): the reply is an MCL_T_PLIST with the id
        const char *nm = "iosurface";
        uint8_t ds[64]; uint32_t selid = 7; memcpy(ds, &selid, 4); strcpy((char *)ds + 4, nm);
        uint64_t ol = 0;
        mcl_call(MCL_OP_DEFSEL, ds, 4 + strlen(nm) + 1, &ol);
        uint8_t batch[sizeof(MclMsgHdr) + 32];
        MclMsgHdr hd = {MCL_MAGIC, 32, 0, 0};
        uint64_t rec[4] = {32 | ((uint64_t)MCL_R_SYNC << 32), selid, [tr[@"r"][@"h"] unsignedLongLongValue], 0};
        memcpy(batch, &hd, sizeof hd); memcpy(batch + sizeof hd, rec, 32);
        const uint8_t *rp = mcl_call(MCL_OP_BATCH, batch, sizeof batch, &ol);
        MclReply r; memcpy(&r, rp, sizeof r);
        CHECK(r.tag == MCL_T_PLIST);
        NSDictionary *fv = [NSPropertyListSerialization propertyListWithData:[NSData dataWithBytes:rp + sizeof r length:r.blen] options:0 format:NULL error:NULL];
        CHECK([fv[@"iosurf"] unsignedIntValue] == sid);
        g = guestDecode(fv);
        CHECK(g && IOSurfaceGetWidth(g) == 64 && IOSurfaceGetHeight(g) == 32);
        CFRelease(g);
        CFRelease(surf);
        printf("PASS: IOSurface id %u round-trips (encObj, decObj, legacy msg, fast batch)\n", sid);

        // 5. object out-parameters (doMsg "outs"): error stays nil on success, carries a domain on failure,
        //    and reflection: and error: get separate slots.
        NSDictionary *bad = rpc(@{@"c": @"msg", @"h": dev[@"h"], @"sel": @"newLibraryWithSource:options:error:",
                                  @"args": @[@"this is not metal", NILV(), @{@"outerr": @YES}]});
        CHECK([bad[@"r"][@"z"] boolValue] && [bad[@"outs"][0][@"e"][@"d"] length] > 0);
        NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "vertex float4 v(uint i [[vertex_id]]) { return float4(0, 0, 0, 1); }\n"
            "fragment float4 f() { return float4(1); }\n";
        NSDictionary *lib = rpc(@{@"c": @"msg", @"h": dev[@"h"], @"sel": @"newLibraryWithSource:options:error:",
                                  @"args": @[src, NILV(), @{@"outerr": @YES}]});
        CHECK(lib[@"r"][@"h"] && [lib[@"outs"][0][@"z"] boolValue]);
        id vf = rpc(@{@"c": @"msg", @"h": lib[@"r"][@"h"], @"sel": @"newFunctionWithName:", @"args": @[@"v"]})[@"r"][@"h"];
        id ff = rpc(@{@"c": @"msg", @"h": lib[@"r"][@"h"], @"sel": @"newFunctionWithName:", @"args": @[@"f"]})[@"r"][@"h"];
        CHECK(vf && ff);
        NSDictionary *pd = @{@"$d": @"MTLRenderPipelineDescriptor", @"p": @[
            @{@"n": @"vertexFunction", @"g": @"vertexFunction", @"s": @"setVertexFunction:", @"t": @"@", @"v": @{@"h": vf}},
            @{@"n": @"fragmentFunction", @"g": @"fragmentFunction", @"s": @"setFragmentFunction:", @"t": @"@", @"v": @{@"h": ff}},
            @{@"n": @"colorAttachments", @"g": @"colorAttachments", @"s": @"", @"t": @"@", @"v": @{@"$d": @"MTLRenderPipelineColorAttachmentDescriptorArray", @"a": @[
                @{@"$d": @"MTLRenderPipelineColorAttachmentDescriptor", @"p": @[
                    @{@"n": @"pixelFormat", @"g": @"pixelFormat", @"s": @"setPixelFormat:", @"t": @"Q", @"v": [NSData dataWithBytes:&(uint64_t){MTLPixelFormatBGRA8Unorm} length:8]}]}]}}]};
        uint64_t opts = MTLPipelineOptionBindingInfo | MTLPipelineOptionBufferTypeInfo;
        NSDictionary *ps = rpc(@{@"c": @"msg", @"h": dev[@"h"], @"sel": @"newRenderPipelineStateWithDescriptor:options:reflection:error:",
                                 @"args": @[pd, [NSData dataWithBytes:&opts length:8], @{@"outerr": @YES}, @{@"outerr": @YES}]});
        CHECK(!ps[@"x"] && ps[@"r"][@"h"]);
        CHECK([ps[@"outs"] count] == 2 && ps[@"outs"][0][@"h"] && [ps[@"outs"][1][@"z"] boolValue]);   // reflection proxy, nil error
        // 6. a bitfield-struct result (usageFlags) through "sig" and the legacy msg path: normalised, 8 bytes, same value
        id rh = ps[@"outs"][0][@"h"];
        NSString *se = rpc(@{@"c": @"sig", @"h": rh, @"sel": @"usageFlags"})[@"t"];
        CHECK([NSMethodSignature signatureWithObjCTypes:se.UTF8String].methodReturnLength == 8);
        NSData *uf = rpc(@{@"c": @"msg", @"h": rh, @"sel": @"usageFlags", @"args": @[]})[@"r"];
        uint64_t direct = ((uint64_t(*)(id, SEL))objc_msgSend)(objFor(rh), sel_registerName("usageFlags"));
        CHECK(uf.length == 8 && *(const uint64_t *)uf.bytes == direct);
        printf("PASS: usageFlags sig %s value 0x%llx\n", se.UTF8String, direct);
        printf("PASS: out-parameters (bad shader -> error domain %s, pipeline -> reflection %s + nil error)\n",
               [bad[@"outs"][0][@"e"][@"d"] UTF8String], [[ps[@"outs"][0][@"c"] firstObject] UTF8String]);
    }
    return 0;
}
