//! Register the running process with the host LaunchServices under the guest
//! `.app` bundle. launchd spawns a GG GUI app (ControlCenter, MenuBarAgent, ...)
//! through the exec redirect, so the host sees the client process as
//! `maclator-exec`, not the app. Native UIKitSystem/FuseBoard resolves a scene
//! client's pid via LaunchServices (`applicationProxyForIdentifier:` /
//! `applicationProxyForBundleURL:` then `[appState isValid]`) and denies the
//! scene when nothing is checked in for that pid, so the menu bar never shows.
//!
//! A single `_LSApplicationCheckIn(kLSDefaultSessionID, info)` associates this
//! pid with the bundle id and URL (verified on-host with `lsappinfo`). This only
//! satisfies the LaunchServices half of the lookup: runningboardd fixes a
//! process's bundle identity from its launchd job label at exec time and never
//! consults LS by pid, so `RBSProcessHandle` by bundle id stays unresolved. The
//! LS record is what the `applicationProxyFor*` fallbacks key on.
//!
//! Host-side only: the guest never sees any of this. Best-effort — any missing
//! symbol or failed call is logged and ignored, never blocking the boot.

use std::os::raw::{c_char, c_int, c_void};

type Ref = *const c_void;

const RTLD_NOW: c_int = 0x2;
const RTLD_GLOBAL: c_int = 0x8;
const UTF8: u32 = 0x0800_0100; // kCFStringEncodingUTF8
const NUM_INT: c_int = 9; // kCFNumberIntType

const CF: &[u8] = b"/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation\0";
const LS: &[u8] =
    b"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/LaunchServices\0";

unsafe fn sym(h: *mut c_void, name: &str) -> *mut c_void {
    let c = std::ffi::CString::new(name).unwrap();
    libc::dlsym(h, c.as_ptr())
}

/// Deref an exported `CFStringRef *` key constant (e.g. `_kLSPIDKey`).
unsafe fn key(h: *mut c_void, name: &str) -> Ref {
    let p = sym(h, name);
    if p.is_null() {
        std::ptr::null()
    } else {
        *(p as *const Ref)
    }
}

/// Nearest ancestor directory whose name ends in `.app`.
fn enclosing_app(exe: &str) -> Option<String> {
    let mut p = std::path::Path::new(exe);
    while let Some(parent) = p.parent() {
        if parent.extension().is_some_and(|e| e == "app") {
            return Some(parent.to_string_lossy().into_owned());
        }
        p = parent;
    }
    None
}

/// If `exe` lives inside a `.app`, check this pid in to LaunchServices as that
/// app. Runs on a scratch thread (as `gpu::preload` does) so host CoreFoundation
/// and XPC state never lands on the guest thread. No-op for non-bundle images.
pub fn register_app(exe: &str) {
    let Some(app) = enclosing_app(exe) else { return };
    let exe = exe.to_string();
    let _ = std::thread::Builder::new()
        .stack_size(1 << 20)
        .spawn(move || unsafe { checkin(&app, &exe) })
        .map(|h| h.join());
}

unsafe fn checkin(app: &str, exe: &str) {
    let cf = libc::dlopen(CF.as_ptr() as *const c_char, RTLD_NOW | RTLD_GLOBAL);
    let ls = libc::dlopen(LS.as_ptr() as *const c_char, RTLD_NOW | RTLD_GLOBAL);
    if cf.is_null() || ls.is_null() {
        return warn("could not load CoreFoundation/LaunchServices");
    }

    // CoreFoundation
    let cfstr: unsafe extern "C" fn(Ref, *const c_char, u32) -> Ref =
        std::mem::transmute(sym(cf, "CFStringCreateWithCString"));
    let url_from_fs: unsafe extern "C" fn(Ref, *const u8, isize, bool) -> Ref =
        std::mem::transmute(sym(cf, "CFURLCreateFromFileSystemRepresentation"));
    let bundle_create: unsafe extern "C" fn(Ref, Ref) -> Ref = std::mem::transmute(sym(cf, "CFBundleCreate"));
    let bundle_id: unsafe extern "C" fn(Ref) -> Ref = std::mem::transmute(sym(cf, "CFBundleGetIdentifier"));
    let info_val: unsafe extern "C" fn(Ref, Ref) -> Ref =
        std::mem::transmute(sym(cf, "CFBundleGetValueForInfoDictionaryKey"));
    let dict_create: unsafe extern "C" fn(Ref, isize, Ref, Ref) -> Ref =
        std::mem::transmute(sym(cf, "CFDictionaryCreateMutable"));
    let dict_set: unsafe extern "C" fn(Ref, Ref, Ref) = std::mem::transmute(sym(cf, "CFDictionarySetValue"));
    let num_create: unsafe extern "C" fn(Ref, c_int, *const c_void) -> Ref =
        std::mem::transmute(sym(cf, "CFNumberCreate"));
    let bool_tid: unsafe extern "C" fn() -> usize = std::mem::transmute(sym(cf, "CFBooleanGetTypeID"));
    let get_tid: unsafe extern "C" fn(Ref) -> usize = std::mem::transmute(sym(cf, "CFGetTypeID"));
    let bool_val: unsafe extern "C" fn(Ref) -> bool = std::mem::transmute(sym(cf, "CFBooleanGetValue"));
    let key_cb = sym(cf, "kCFTypeDictionaryKeyCallBacks");
    let val_cb = sym(cf, "kCFTypeDictionaryValueCallBacks");
    let bool_true = key(cf, "kCFBooleanTrue");

    // LaunchServices
    let check_in: unsafe extern "C" fn(c_int, Ref) -> Ref = std::mem::transmute(sym(ls, "_LSApplicationCheckIn"));
    if (check_in as *const c_void).is_null() || key_cb.is_null() || val_cb.is_null() {
        return warn("missing LaunchServices/CoreFoundation symbols");
    }

    let cs = |s: &str| -> Ref {
        let c = std::ffi::CString::new(s).unwrap();
        cfstr(std::ptr::null(), c.as_ptr(), UTF8)
    };

    // Bundle id and app type from the .app's Info.plist (handles binary plists).
    let app_url = url_from_fs(std::ptr::null(), app.as_ptr(), app.len() as isize, true);
    let bundle = if app_url.is_null() { std::ptr::null() } else { bundle_create(std::ptr::null(), app_url) };
    let bid = if bundle.is_null() { std::ptr::null() } else { bundle_id(bundle) };
    if bid.is_null() {
        return warn(&format!("no CFBundleIdentifier for {app}"));
    }
    let app_type = bundle_info_type(bundle, info_val, get_tid, bool_tid, bool_val, &cs);

    let d = dict_create(std::ptr::null(), 0, key_cb as Ref, val_cb as Ref);
    dict_set(d, key(ls, "_kLSBundlePathKey"), cs(app));
    dict_set(d, key(ls, "_kLSExecutablePathKey"), cs(exe));
    dict_set(d, cs("CFBundleIdentifier"), bid); // plain Info.plist key populates lsappinfo bundleID
    dict_set(d, key(ls, "_kLSApplicationTypeKey"), cs(app_type));
    if !bool_true.is_null() {
        dict_set(d, key(ls, "_kLSApplicationHasSignalledItIsReadyKey"), bool_true);
        dict_set(d, key(ls, "_kLSApplicationHasRegisteredKey"), bool_true);
    }
    let pid: c_int = libc::getpid();
    let npid = num_create(std::ptr::null(), NUM_INT, &pid as *const c_int as *const c_void);
    dict_set(d, key(ls, "_kLSPIDKey"), npid);

    let asn = check_in(-2 /* kLSDefaultSessionID */, d);
    if asn.is_null() {
        warn(&format!("_LSApplicationCheckIn returned NULL for {app}"));
    } else if crate::syscalls::TRACE.load(std::sync::atomic::Ordering::Relaxed) {
        eprintln!("[maclator] checked in to LaunchServices as {app} ({app_type})");
    }
}

/// `"UIElement"` (LSUIElement), `"BackgroundOnly"` (LSBackgroundOnly), else `"Foreground"`.
unsafe fn bundle_info_type(
    bundle: Ref,
    info_val: unsafe extern "C" fn(Ref, Ref) -> Ref,
    get_tid: unsafe extern "C" fn(Ref) -> usize,
    bool_tid: unsafe extern "C" fn() -> usize,
    bool_val: unsafe extern "C" fn(Ref) -> bool,
    cs: &dyn Fn(&str) -> Ref,
) -> &'static str {
    let truthy = |v: Ref| -> bool { !v.is_null() && get_tid(v) == bool_tid() && bool_val(v) };
    if truthy(info_val(bundle, cs("LSUIElement"))) {
        "UIElement"
    } else if truthy(info_val(bundle, cs("LSBackgroundOnly"))) {
        "BackgroundOnly"
    } else {
        "Foreground"
    }
}

fn warn(msg: &str) {
    eprintln!("maclator-exec: lsreg: {msg}");
    if let Ok(c) = std::ffi::CString::new(format!("maclator-exec: lsreg: {msg}")) {
        unsafe { libc::syslog(libc::LOG_ERR, b"%s\0".as_ptr() as *const c_char, c.as_ptr()) };
    }
}
