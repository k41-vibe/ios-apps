/*
 * xpcshim.m - hand iosc's Metal fence over inside the process, instead of through
 * the root XPC service "com.max.xios.metal-event-broker".
 *
 * At startup iosc publishes its MTLSharedEvent as an MTLSharedEventHandle plus a
 * 32-byte token through that service, which on a jailbroken device is a root
 * LaunchDaemon (x11/apps/shared/XiosMetalEventBroker.m:15-41, 66-110). We cannot
 * register it, and there is no unfenced fallback anywhere in the source:
 *
 *     xios_metal_sync_create_event() == NULL
 *      -> iosc_gl.c:318-325 "output release timeline unavailable" -> -1
 *      -> iosc.c:6921-6924  "FATAL: GPU compositor initialization failed" -> exit 1
 *
 * (tools/xios/iosc-host-protocol.md section 4.)
 *
 * Everything runs in ONE process here (procd.c runs iosc on a thread), so the event
 * object can simply be handed over directly. The broker is statically linked into the
 * iosc image, so its C calls are direct branches and symbol interposition cannot reach
 * them - but it talks to the service through Objective-C, and ObjC dispatch is always
 * dynamic. So we hook there. XiosMetalEventBroker.m:13-48 builds a fresh connection on
 * every call (nothing is cached):
 *
 *     Class cls = NSClassFromString(@"NSXPCConnection");
 *     SEL   s   = NSSelectorFromString(@"initWithMachServiceName:options:");
 *     if (!cls || ![cls instancesRespondToSelector:s]) return nil;  // -> publish fails -> FATAL
 *     connection = objc_msgSend([cls alloc], s, @"com.max.xios.metal-event-broker",
 *                               (NSUInteger)NSXPCConnectionPrivileged);  // 1<<12
 *     connection.remoteObjectInterface = <NSXPCInterface for the protocol below>;
 *     [connection resume];
 *     id proxy = [connection synchronousRemoteObjectProxyWithErrorHandler:^(NSError *e){ ... }];
 *
 * We swizzle initWithMachServiceName:options: to remember the service name on the
 * connection, and both proxy getters to return a local stub for that one name. Every
 * other NSXPCConnection keeps its original behaviour: the original IMPs are kept in
 * file statics and called through.
 *
 * The protocol we stand in for (XiosMetalEventBroker.h:25-31):
 *
 *     - (void)publishHandle:(MTLSharedEventHandle *)handle token:(NSData *)token
 *                 withReply:(void (^)(BOOL stored))reply;
 *     - (void)copyHandleForToken:(NSData *)token
 *                      withReply:(void (^)(MTLSharedEventHandle *handle))reply;
 *
 * The caller reads __block locals immediately after the call, so the reply block MUST
 * be invoked synchronously, inline, before we return. publish is retried up to 4 times
 * while stored == NO and the error handler has not fired; it needs 1 (= YES) to go on.
 * copyHandleForToken: is the client side (XScreen.swift:1376-1407); implemented for
 * symmetry so our own Swift client can use the same table later.
 *
 * MTLSharedEventHandle is typed as `id` and <Metal/Metal.h> is NOT imported on purpose:
 * the handles are completely opaque to us (we only store and return them), so this
 * costs nothing and avoids both the header and any class-availability risk. ObjC
 * dispatch is by selector, so the caller's typed call site is unaffected.
 *
 * Memory management is MANUAL (no -fobjc-arc; postbuild.sh compiles *.m with the same
 * flags as *.c). Everything we own lives for the life of the process: the stub is a
 * singleton and the table retains every handle it is handed, so nothing we return can
 * die under the caller. We create no autoreleased objects on a guest thread - procd's
 * pthreads run without an autorelease pool.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <string.h>

#include "lcsys.h"

#define LC_BROKER_NAME "com.max.xios.metal-event-broker"

typedef void (^lc_publish_reply)(BOOL stored);
typedef void (^lc_handle_reply)(id handle);
typedef void (^lc_error_handler)(NSError *error);

/* ------------------------------------------------------------------ helpers */

/* First 4 bytes of the 32-byte token, for the log. */
static void lc_token_hex(id token, char *out, size_t cap)
{
    const unsigned char *b = NULL;
    size_t n = 0, i;

    if ([token isKindOfClass:[NSData class]]) {
        b = (const unsigned char *)[(NSData *)token bytes];
        n = (size_t)[(NSData *)token length];
    }
    if (!b || n == 0 || cap < 9) {
        snprintf(out, cap, "-");
        return;
    }
    if (n > 4)
        n = 4;
    for (i = 0; i < n; i++)
        snprintf(out + i * 2, cap - i * 2, "%02x", b[i]);
}

/* --------------------------------------------------------------- the stub */

@interface LCMetalEventBroker : NSObject
/* +1, or nil. Used by lcsys_shared_event_for_token() below. */
- (id)copyHandleForTokenData:(NSData *)token count:(unsigned long *)count;
@end

/* -newSharedEventWithHandle: is id<MTLDevice>'s, but importing <Metal/Metal.h> here
 * would drag the whole framework in for one selector (see the file header: the handles
 * stay opaque on purpose). Declaring it on NSObject is enough for the compiler to emit
 * the right message send, and the "new" family keeps the +1 return under MRR. */
@interface NSObject (LCMetalDevice)
- (id)newSharedEventWithHandle:(id)handle;
@end

@implementation LCMetalEventBroker {
    NSMutableDictionary *_table;   /* NSData token -> MTLSharedEventHandle (retained) */
    NSLock *_lock;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        /* alloc/init, not the class convenience methods: those return autoreleased
         * objects and we may well be on a guest thread with no pool. */
        _table = [[NSMutableDictionary alloc] init];
        _lock = [[NSLock alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [_table release];
    [_lock release];
    [super dealloc];
}

- (void)publishHandle:(id)handle token:(id)token withReply:(lc_publish_reply)reply
{
    char hex[9];
    BOOL stored = NO;
    unsigned long count = 0;

    lc_token_hex(token, hex, sizeof hex);
    if (handle && [token isKindOfClass:[NSData class]] && [(NSData *)token length] > 0) {
        [_lock lock];
        /* setObject:forKey: retains the handle and copies the key, so the handle
         * outlives this call and every later lookup without an autorelease. */
        [_table setObject:handle forKey:(NSData *)token];
        count = (unsigned long)[_table count];
        [_lock unlock];
        stored = YES;
    }
    lcsys_log("xpcshim: publish token=%s%s table=%lu", hex, stored ? "" : " REJECTED", count);
    /* Inline, before returning, and outside the lock: the caller reads a __block
     * local right after this and retries while stored == NO. */
    if (reply)
        reply(stored);
}

- (id)copyHandleForTokenData:(NSData *)token count:(unsigned long *)count
{
    id handle = nil;

    if (![token isKindOfClass:[NSData class]])
        return nil;
    [_lock lock];
    handle = [[_table objectForKey:token] retain];
    if (count)
        *count = (unsigned long)[_table count];
    [_lock unlock];
    return handle;                /* +1 */
}

- (void)copyHandleForToken:(id)token withReply:(lc_handle_reply)reply
{
    char hex[9];
    id handle = nil;
    unsigned long count = 0;

    lc_token_hex(token, hex, sizeof hex);
    handle = [self copyHandleForTokenData:(NSData *)token count:&count];
    lcsys_log("xpcshim: lookup token=%s -> %s table=%lu", hex, handle ? "hit" : "MISS", count);
    if (reply)
        reply(handle);            /* inline; nil when absent, like the real broker */
    [handle release];             /* balanced - the table still holds its own reference */
}

@end

/* ------------------------------------------------------- swizzle machinery */

static char lc_service_key;            /* its address is the associated-object key */
static LCMetalEventBroker *lc_stub;    /* singleton, deliberately never released */

typedef id (*lc_init_fn)(id, SEL, id, NSUInteger);
typedef id (*lc_proxy_fn)(id, SEL, lc_error_handler);
typedef void (*lc_void_fn)(id, SEL);

static lc_init_fn lc_orig_init;
static lc_proxy_fn lc_orig_sync_proxy;
static lc_proxy_fn lc_orig_async_proxy;
static lc_void_fn lc_orig_resume;
static lc_void_fn lc_orig_invalidate;

static BOOL lc_is_broker(id connection)
{
    id name = objc_getAssociatedObject(connection, &lc_service_key);

    /* @"..." is a compile-time constant object: no allocation, no pool needed. */
    return name && [name isKindOfClass:[NSString class]] &&
           [(NSString *)name isEqualToString:@"com.max.xios.metal-event-broker"];
}

/* Replace one instance method, returning the implementation that was there.
 * class_getInstanceMethod also finds INHERITED methods, and method_setImplementation
 * on one of those would patch the superclass for everybody; in that case add an
 * override on cls instead and treat the inherited IMP as the original. */
static IMP lc_swizzle(Class cls, SEL sel, IMP replacement, const char *types)
{
    Method m = class_getInstanceMethod(cls, sel);
    Class parent;   /* not named `super`: that is a context-sensitive ObjC keyword */

    if (!m)
        return NULL;
    parent = class_getSuperclass(cls);
    if (parent && class_getInstanceMethod(parent, sel) == m) {
        IMP inherited = method_getImplementation(m);
        if (class_addMethod(cls, sel, replacement, types ? types : method_getTypeEncoding(m)))
            return inherited;
        m = class_getInstanceMethod(cls, sel);   /* lost a race; patch it in place */
    }
    return method_setImplementation(m, replacement);
}

/* initWithMachServiceName:options: - call the original, then record the name. */
static id lc_init_mach_service(id self, SEL _cmd, id name, NSUInteger options)
{
    id conn = lc_orig_init ? lc_orig_init(self, _cmd, name, options) : self;

    if (conn && name && [name isKindOfClass:[NSString class]]) {
        /* COPY_NONATOMIC: the runtime owns the copy and drops it when conn deallocs,
         * and reading it back neither retains nor autoreleases. */
        objc_setAssociatedObject(conn, &lc_service_key, name, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    return conn;
}

static id lc_proxy_common(id self, SEL _cmd, lc_error_handler handler, lc_proxy_fn orig)
{
    if (lc_is_broker(self)) {
        lcsys_log("xpcshim: %s -> local stub (no XPC)", sel_getName(_cmd));
        /* +0, exactly like the real getter. The singleton never dies, and we do NOT
         * call the error handler: from the caller's point of view nothing failed. */
        return lc_stub;
    }
    if (orig)
        return orig(self, _cmd, handler);
    return nil;
}

static id lc_sync_proxy(id self, SEL _cmd, lc_error_handler handler)
{
    return lc_proxy_common(self, _cmd, handler, lc_orig_sync_proxy);
}

static id lc_async_proxy(id self, SEL _cmd, lc_error_handler handler)
{
    return lc_proxy_common(self, _cmd, handler, lc_orig_async_proxy);
}

/* --------------------------------- fallback: no NSXPCConnection in the image */

/* Only reachable when NSClassFromString(@"NSXPCConnection") is nil, i.e. nothing else
 * in the process can be using NSXPC either - so a class that only knows how to be our
 * broker is enough. It implements exactly the six selectors XiosMetalEventBroker.m
 * uses; anything else would be an unrecognised selector. */
static id lc_fake_init(id self, SEL _cmd, id name, NSUInteger options)
{
    (void)_cmd;
    (void)options;
    if (self && name && [name isKindOfClass:[NSString class]])
        objc_setAssociatedObject(self, &lc_service_key, name, OBJC_ASSOCIATION_COPY_NONATOMIC);
    return self;
}

static void lc_fake_void(id self, SEL _cmd)             { (void)self; (void)_cmd; }
static void lc_fake_set_object(id self, SEL _cmd, id a) { (void)self; (void)_cmd; (void)a; }

static id lc_fake_proxy(id self, SEL _cmd, lc_error_handler handler)
{
    if (lc_is_broker(self)) {
        lcsys_log("xpcshim: %s -> local stub (synthesised NSXPCConnection)", sel_getName(_cmd));
        return lc_stub;
    }
    if (handler) {
        @autoreleasepool {
            /* 4099 = NSXPCConnectionInvalid. The handler runs inside the pool, so the
             * error is alive for the whole call. */
            handler([NSError errorWithDomain:NSCocoaErrorDomain code:4099 userInfo:nil]);
        }
    }
    return nil;
}

static Class lc_synthesise_class(void)
{
    /* arm64 type encodings: NSUInteger -> 'Q', block -> '@?' */
    Class cls = objc_allocateClassPair([NSObject class], "NSXPCConnection", 0);

    if (!cls)
        return NULL;
    class_addMethod(cls, sel_registerName("initWithMachServiceName:options:"),
                    (IMP)lc_fake_init, "@@:@Q");
    class_addMethod(cls, sel_registerName("setRemoteObjectInterface:"),
                    (IMP)lc_fake_set_object, "v@:@");
    class_addMethod(cls, sel_registerName("resume"), (IMP)lc_fake_void, "v@:");
    class_addMethod(cls, sel_registerName("invalidate"), (IMP)lc_fake_void, "v@:");
    class_addMethod(cls, sel_registerName("synchronousRemoteObjectProxyWithErrorHandler:"),
                    (IMP)lc_fake_proxy, "@@:@?");
    class_addMethod(cls, sel_registerName("remoteObjectProxyWithErrorHandler:"),
                    (IMP)lc_fake_proxy, "@@:@?");
    objc_registerClassPair(cls);
    return cls;
}

/* -resume / -invalidate on a broker connection must never reach the real XPC machinery:
 * the privileged service does not exist here, and we have already taken over the proxy, so
 * the only thing a real resume could still do is tear the connection down asynchronously
 * (and, on some OS versions, complain loudly). Non-broker connections are untouched. */
static void lc_resume(id self, SEL _cmd)
{
    if (lc_is_broker(self)) {
        lcsys_log("xpcshim: -resume swallowed for %s", LC_BROKER_NAME);
        return;
    }
    if (lc_orig_resume)
        lc_orig_resume(self, _cmd);
}

static void lc_invalidate(id self, SEL _cmd)
{
    if (lc_is_broker(self))
        return;
    if (lc_orig_invalidate)
        lc_orig_invalidate(self, _cmd);
}

/* ----------------------------------------------------------------- install */

static void lc_install_once(void)
{
    SEL init_sel = sel_registerName("initWithMachServiceName:options:");
    SEL sync_sel = sel_registerName("synchronousRemoteObjectProxyWithErrorHandler:");
    SEL async_sel = sel_registerName("remoteObjectProxyWithErrorHandler:");
    Class cls;

    lc_stub = [[LCMetalEventBroker alloc] init];

    cls = NSClassFromString(@"NSXPCConnection");
    if (!cls) {
        cls = lc_synthesise_class();
        lcsys_log("xpcshim: NSXPCConnection absent -> synthesised class %s for %s",
                  cls ? "ok" : "FAILED", LC_BROKER_NAME);
        return;
    }

    lc_orig_init = (lc_init_fn)lc_swizzle(cls, init_sel, (IMP)lc_init_mach_service, "@@:@Q");
    lc_orig_sync_proxy = (lc_proxy_fn)lc_swizzle(cls, sync_sel, (IMP)lc_sync_proxy, "@@:@?");
    lc_orig_async_proxy = (lc_proxy_fn)lc_swizzle(cls, async_sel, (IMP)lc_async_proxy, "@@:@?");
    lc_orig_resume = (lc_void_fn)lc_swizzle(cls, sel_registerName("resume"), (IMP)lc_resume, "v@:");
    lc_orig_invalidate = (lc_void_fn)lc_swizzle(cls, sel_registerName("invalidate"), (IMP)lc_invalidate, "v@:");
    /* All three must be non-NULL. A missing proxy getter means the real XPC call would
     * still be made -> publish fails -> iosc.c:6921 FATAL, so make it obvious here. */
    lcsys_log("xpcshim: swizzled NSXPCConnection init=%s sync=%s async=%s resume=%s invalidate=%s for %s",
              lc_orig_init ? "ok" : "MISSING",
              lc_orig_sync_proxy ? "ok" : "MISSING",
              lc_orig_async_proxy ? "ok" : "MISSING",
              lc_orig_resume ? "ok" : "MISSING",
              lc_orig_invalidate ? "ok" : "MISSING", LC_BROKER_NAME);
}

void lcsys_install_xpc_shim(void)
{
    static dispatch_once_t once;

    dispatch_once(&once, ^{ lc_install_once(); });
}

/* ------------------------------------- the client half: token -> MTLSharedEvent */

/* The in-process replacement for xios_metal_event_broker_copy_event(device, token, 32)
 * (XScreen.swift:1376-1407 calls it for both timelines). iosc published the handle
 * into the very same table above, so this is a dictionary lookup plus one
 * -newSharedEventWithHandle:. Same process, same device, so the event we hand back is
 * the one iosc is signalling.
 *
 * Returns +1 (the caller owns it); NULL when the token is unknown or the device does
 * not answer the selector. Callable from any thread. */
void *lcsys_shared_event_for_token(void *mtl_device, const unsigned char *token, size_t len)
{
    id device = (id)mtl_device;
    NSData *key;
    id handle;
    id event = nil;
    unsigned long count = 0;
    char hex[9];

    if (!device || !token || len == 0) {
        lcsys_log("xpcshim: shared_event_for_token called with device=%p token=%p len=%zu", mtl_device,
                  (const void *)token, len);
        return NULL;
    }
    /* iosc may not have run yet when a caller asks first; installing is idempotent. */
    lcsys_install_xpc_shim();
    if (!lc_stub)
        return NULL;

    @autoreleasepool {
        key = [[NSData alloc] initWithBytes:token length:len];
        lc_token_hex(key, hex, sizeof hex);
        handle = [lc_stub copyHandleForTokenData:key count:&count];
        [key release];
        if (!handle) {
            lcsys_log("xpcshim: shared event token=%s MISS (table=%lu) - iosc has not published it",
                      hex, count);
            return NULL;
        }
        if ([device respondsToSelector:@selector(newSharedEventWithHandle:)])
            event = [device newSharedEventWithHandle:handle];   /* +1 */
        else
            lcsys_log("xpcshim: %s does not respond to newSharedEventWithHandle:",
                      class_getName(object_getClass(device)));
        [handle release];
        lcsys_log("xpcshim: shared event token=%s -> %s (table=%lu)", hex, event ? "ok" : "FAILED", count);
    }
    return (void *)event;
}
