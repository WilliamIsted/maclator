// Host-only audit of the method signature path (mclbridge.m normEnc / hostSig). For every method of the
// classes below, compares the old path (NSMethodSignature from the raw runtime encoding, then
// NSGetSizeAndAlignment on each type, as the shim's buildPlan / forwardInvocation do) with the normalised one.
// A method fails if anything throws or a size differs from the host's (NSGetSizeAndAlignment of the raw
// type when it can, else the C-layout estimate in tinfo). Run from gpu/:
//   clang -arch x86_64 -fobjc-arc -framework Foundation -framework Metal -framework IOSurface tests-ios/sig-audit.m -o out-ios4/sig-audit && out-ios4/sig-audit [all]
#include "../mclbridge.m"

static NSUInteger hostSize(const char *t, BOOL *est) {
    NSUInteger s = 0, a;
    @try { NSGetSizeAndAlignment(t, &s, NULL); return s; } @catch (NSException *e) {}
    BOOL c = YES; const char *p = t;
    tinfo(&p, &s, &a, &c);
    *est = YES;
    return s;
}

// nil = fine, else why not
static NSString *check(const char *raw, const char *enc) {
    @try {
        NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:enc];
        const char *p = raw;
        for (NSUInteger i = 0; *p && i <= sig.numberOfArguments; i++) {
            const char *start = p; NSUInteger s, a; BOOL c = YES;
            tinfo(&p, &s, &a, &c);
            NSString *el = [[NSString alloc] initWithBytes:start length:p - start encoding:NSUTF8StringEncoding];
            while (*p >= '0' && *p <= '9') p++;
            if (i > sig.numberOfArguments) break;
            const char *t = i == 0 ? sig.methodReturnType : [sig getArgumentTypeAtIndex:i - 1];
            NSUInteger got = 0;
            NSGetSizeAndAlignment(t, &got, NULL);
            BOOL est = NO;
            NSUInteger want = hostSize(el.UTF8String, &est);
            if (*skipQual(el.UTF8String) == '[' && i) want = 8;   // array parameters are pointers
            if (got != want) return [NSString stringWithFormat:@"type %lu '%s' size %lu, host %lu%s", i, t, got, want, est ? " (est)" : ""];
            if (i == 0 && t[0] != 'v' && sig.methodReturnLength != want) return [NSString stringWithFormat:@"return length %lu, host %lu", sig.methodReturnLength, want];
        }
        return nil;
    } @catch (NSException *e) { return e.reason; }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        id dev = MTLCreateSystemDefaultDevice();
        NSMutableArray *names = [@[@"MTLRenderPipelineReflectionInternal", @"MTLComputePipelineReflectionInternal", @"MTLBufferBindingInternal",
            @"MTLArgument", @"MTLStructType", @"MTLStructMember", @"MTLArrayType", @"MTLPointerType", @"MTLTextureReferenceType", @"MTLType",
            @"MTLIOAccelTexture", @"MTLIOAccelGLDrawable", @(object_getClassName(dev))] mutableCopy];
        if (argc > 1) {   // "all": every MTL / GFX class loaded
            unsigned n; Class *cl = objc_copyClassList(&n);
            for (unsigned i = 0; i < n; i++) { const char *cn = class_getName(cl[i]); if (!strncmp(cn, "MTL", 3) || !strncmp(cn, "_MTL", 4) || !strncmp(cn, "GFX", 3)) [names addObject:@(cn)]; }
            free(cl);
        }
        NSMutableSet *seen = [NSMutableSet set];
        int total = 0, oldFail = 0, newFail = 0;
        for (NSString *nm in names) {
            for (Class c = NSClassFromString(nm); c && c != [NSObject class]; c = class_getSuperclass(c)) {
                unsigned n; Method *ml = class_copyMethodList(c, &n);
                for (unsigned i = 0; i < n; i++) {
                    NSString *key = [NSString stringWithFormat:@"%s %s", class_getName(c), sel_getName(method_getName(ml[i]))];
                    if ([seen containsObject:key]) continue;
                    [seen addObject:key];
                    const char *raw = method_getTypeEncoding(ml[i]);
                    if (!raw) continue;
                    total++;
                    NSString *o = check(raw, raw), *nw = check(raw, normEnc(raw).UTF8String);
                    if (o) { oldFail++; if (argc < 2 || oldFail <= 15) printf("old  %s %s: %s\n", key.UTF8String, raw, o.UTF8String); }
                    if (nw) { newFail++; printf("NEW  %s %s -> %s: %s\n", key.UTF8String, raw, normEnc(raw).UTF8String, nw.UTF8String); }
                }
                free(ml);
            }
        }
        printf("%s: %d methods, %d fail on the old path, %d fail after normEnc\n", newFail ? "FAIL" : "PASS", total, oldFail, newFail);
        printf("usageFlags -> %s\n", normEnc(method_getTypeEncoding(class_getInstanceMethod(NSClassFromString(@"MTLRenderPipelineReflectionInternal"), sel_registerName("usageFlags")))).UTF8String);
        return newFail != 0;
    }
}
