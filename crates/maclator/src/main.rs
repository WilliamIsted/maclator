//! Maclator: run arm64 macOS programs on x86-64 Macs.

mod aot;
mod cache;
mod commpage;
mod engine;
mod gpu;
mod guestmem;
mod hostsys;
mod iokit;
mod jit;
mod loader;
mod macho;
mod paths;
mod signals;
mod spawn;
mod symbols;
mod syscalls;
mod threads;
mod workq;

use std::sync::atomic::Ordering;

fn usage() -> ! {
    eprintln!("usage: maclator [options] <arm64-program> [args...]");
    eprintln!("       maclator --aot <arm64-program>     translate ahead of time and exit");
    eprintln!("options:");
    eprintln!("  --interp        interpreter only (no JIT/AOT)");
    eprintln!("  --no-aot        JIT only: don't load or build AOT translations");
    eprintln!("  --dyld PATH     arm64 dyld to use (default /usr/lib/dyld)");
    eprintln!("  --sysroot DIR   directory with the arm64 dyld shared cache files");
    eprintln!("  --trace         trace system calls");
    eprintln!("  --gpu           route the guest's Metal API to the host GPU");
    std::process::exit(2);
}

fn main() {
    let argv0 = std::env::args().next().unwrap_or_default();
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    // Kernel-chosen interpreter: `maclator-exec <target> <args...>` (the #! convention), or `--auto`.
    let auto = argv0.rsplit('/').next() == Some("maclator-exec") || args.first().map(|a| a == "--auto").unwrap_or(false);
    if auto {
        if args.first().map(|a| a == "--auto").unwrap_or(false) {
            args.remove(0);
        }
        AUTO.store(true, Ordering::Relaxed);
        // Config options go first, so flags that spawn.rs forwards to re-launched children override them.
        let mut opts = auto_options(&conf_path());
        opts.append(&mut args);
        args = opts;
    }
    let mut dyld = std::env::var("MACLATOR_DYLD").unwrap_or_else(|_| "/usr/lib/dyld".to_string());
    while let Some(a) = args.first().cloned() {
        match a.as_str() {
            "--trace-file" => {
                // Trace to /tmp/maclator-trace-<pid>.log (helper processes have no usable stderr).
                syscalls::TRACE.store(true, Ordering::Relaxed);
                std::env::set_var("MACLATOR_TRACE_FILE", "1");
                args.remove(0);
            }
            "--dump-on-fault" => {
                std::env::set_var("MACLATOR_DUMP_ON_FAULT", "1");
                args.remove(0);
            }
            "--trace" => {
                syscalls::TRACE.store(true, Ordering::Relaxed);
                args.remove(0);
            }
            "--dyld" => {
                args.remove(0);
                if args.is_empty() {
                    usage();
                }
                dyld = args.remove(0);
            }
            "--gpu" => {
                // Route the guest's Metal API to the host GPU (see gpu.rs).
                std::env::set_var("MACLATOR_GPU", "1");
                args.remove(0);
            }
            "--gpu-only" => {
                // Only guest processes whose arguments contain SUBSTR get the GPU (e.g. --type=gpu-process);
                // others run untouched (saves the bridge start-up cost in every helper process).
                args.remove(0);
                if args.is_empty() {
                    usage();
                }
                std::env::set_var("MACLATOR_GPU_ONLY", args.remove(0));
            }
            "--interp" => {
                jit::JIT_ENABLED.store(false, Ordering::Relaxed);
                aot::set_enabled(false);
                args.remove(0);
            }
            "--no-aot" => {
                aot::set_enabled(false);
                args.remove(0);
            }
            "--sysroot" => {
                args.remove(0);
                if args.is_empty() {
                    usage();
                }
                paths::set_cache_dir(&args.remove(0));
            }
            "--aot" => {
                args.remove(0);
                if args.is_empty() {
                    usage();
                }
                let exe = resolve_path(&args[0]);
                match aot::build_standalone(&exe) {
                    Ok(n) => {
                        eprintln!("maclator: translated {n} blocks of {exe} ahead of time");
                        std::process::exit(0);
                    }
                    Err(e) => {
                        eprintln!("maclator: aot: {e}");
                        std::process::exit(1);
                    }
                }
            }
            "--jit-dump" => {
                aot::set_enabled(false);
                let words: Vec<u32> = args[1..].iter().filter_map(|w| u32::from_str_radix(w.trim_start_matches("0x"), 16).ok()).collect();
                jit::selftest::dump_block(&words);
                std::process::exit(0);
            }
            "--selftest-jit" => {
                let class = args.get(1).cloned().unwrap_or_else(|| "dpreg".into());
                let n = args.get(2).and_then(|v| v.parse().ok()).unwrap_or(20000);
                aot::set_enabled(false);
                jit::selftest::run_selftest(&class, n);
                std::process::exit(0);
            }
            "-h" | "--help" => usage(),
            _ => break,
        }
    }
    if args.is_empty() {
        if AUTO.load(Ordering::Relaxed) {
            fail("no target program");
        }
        usage();
    }
    if AUTO.load(Ordering::Relaxed) && !std::path::Path::new(&args[0]).exists() {
        fail(&format!("{}: no such file", args[0]));
    }
    if paths::cache_dir().is_none() && !std::path::Path::new("/System/Library/dyld/dyld_shared_cache_arm64e").exists() {
        if let Some(d) = paths::discover_sysroot() {
            paths::set_cache_dir(&d);
        }
    }
    {
        // Options that re-launched arm64 children must inherit.
        let mut fwd: Vec<String> = vec!["--dyld".into(), dyld.clone()];
        if let Some(d) = paths::cache_dir() {
            fwd.push("--sysroot".into());
            fwd.push(d);
        }
        if !jit::JIT_ENABLED.load(Ordering::Relaxed) {
            fwd.push("--interp".into());
        }
        if std::env::var_os("MACLATOR_GPU").is_some() {
            fwd.push("--gpu".into());
            if let Ok(o) = std::env::var("MACLATOR_GPU_ONLY") {
                fwd.push("--gpu-only".into());
                fwd.push(o);
            }
        }
        if std::env::var_os("MACLATOR_TRACE_FILE").is_some() {
            fwd.push("--trace-file".into());
        } else if syscalls::TRACE.load(Ordering::Relaxed) {
            fwd.push("--trace".into());
        }
        if std::env::var_os("MACLATOR_DUMP_ON_FAULT").is_some() {
            fwd.push("--dump-on-fault".into());
        }
        spawn::configure(fwd);
    }
    if std::env::var_os("MACLATOR_TRACE").is_some() {
        syscalls::TRACE.store(true, Ordering::Relaxed);
    }
    let exe = resolve_path(&args[0]);
    let gpu_active = std::env::var_os("MACLATOR_GPU").is_some()
        && std::env::var("MACLATOR_GPU_ONLY").map(|o| args.iter().skip(1).any(|a| a.contains(&o))).unwrap_or(true);
    let mut envp: Vec<String> = std::env::vars()
        .filter(|(k, _)| !k.starts_with("MACLATOR_") || matches!(k.as_str(), "MACLATOR_DUMP_ON_FAULT" | "MACLATOR_GPU_BRIDGE" | "MACLATOR_JIT_THRESHOLD" | "MACLATOR_STATS" | "MACLATOR_FALLBACK_HIST"))
        .map(|(k, v)| format!("{k}={v}"))
        .collect();

    if gpu_active && !gpu::inject(&mut envp) {
        eprintln!("maclator: --gpu: libmclmetal.dylib not found (looked next to maclator, in ./gpu, ~/.maclator/gpu, $MACLATOR_GPU_DIR)");
    }
    if std::env::var_os("MACLATOR_TRACE_FILE").is_some() {
        unsafe {
            let path = format!("/tmp/maclator-trace-{}.log\0", libc::getpid());
            let fd = libc::open(path.as_ptr() as *const libc::c_char, libc::O_WRONLY | libc::O_CREAT | libc::O_TRUNC, 0o644);
            if fd >= 0 {
                libc::dup2(fd, 2);
            }
        }
    }
    if gpu_active {
        // The host frameworks must be initialised before the guest runs: CoreFoundation's
        // initialiser disturbs the guest's LaunchServices/XPC state when run mid-flight.
        gpu::preload();
    }
    engine::install_debug_handler();
    let cp = commpage::CommPage::install();
    if syscalls::TRACE.load(Ordering::Relaxed) {
        eprintln!("[maclator] commpage {} at {:#x}", if cp.in_place { "in place" } else { "redirected" }, cp.base);
    }
    let (loaded, mut cpu) = match loader::load(&exe, &dyld, &args, &envp) {
        Ok(v) => v,
        Err(e) => {
            if AUTO.load(Ordering::Relaxed) {
                fail(&format!("{exe}: {e}"));
            }
            eprintln!("maclator: {e}");
            std::process::exit(1);
        }
    };
    let (lo, hi) = loaded.main.macho.vm_range();
    symbols::add_image(lo.wrapping_add(loaded.main.slide), hi.wrapping_add(loaded.main.slide), exe.rsplit('/').next().unwrap_or(&exe));
    let (lo, hi) = loaded.dyld.macho.vm_range();
    symbols::add_image(lo.wrapping_add(loaded.dyld.slide), hi.wrapping_add(loaded.dyld.slide), "dyld");
    if syscalls::TRACE.load(Ordering::Relaxed) {
        eprintln!("[maclator] main at {:#x}, dyld entry {:#x}, sp {:#x}", loaded.main.base, loaded.entry, loaded.sp);
    }
    {
        let m = &loaded.main.macho;
        let (lo, hi) = m.vm_range();
        let entries = aot::function_starts(&exe, m, loaded.main.slide);
        aot::register_main(&exe, m.uuid, lo.wrapping_add(loaded.main.slide), hi.wrapping_add(loaded.main.slide), entries);
        let d = &loaded.dyld.macho;
        let (lo, hi) = d.vm_range();
        aot::register_dyld(&dyld, d.uuid, lo.wrapping_add(loaded.dyld.slide), hi.wrapping_add(loaded.dyld.slide));
    }
    engine::run_thread(&mut cpu);
    // The main thread ended (pthread_exit on main): wait for other threads.
    while threads::LIVE_THREADS.load(Ordering::SeqCst) > 1 {
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    std::process::exit(0);
}

/// Set in auto mode: failures go to syslog too and exit 126.
static AUTO: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

fn conf_path() -> String {
    std::env::var("MACLATOR_CONF").unwrap_or_else(|_| "/usr/local/etc/maclator.conf".to_string())
}

/// Auto-mode failure: stderr and syslog, exit 126 (as a shell does for "found but cannot execute").
fn fail(msg: &str) -> ! {
    eprintln!("maclator-exec: {msg}");
    if let Ok(c) = std::ffi::CString::new(format!("maclator-exec: {msg}")) {
        unsafe { libc::syslog(libc::LOG_ERR, b"%s\0".as_ptr() as *const libc::c_char, c.as_ptr()) };
    }
    std::process::exit(126);
}

/// Read `key=value` lines from the auto-mode config and turn them into command-line options.
/// Keys: `sysroot`, `dyld`, `gpu` (1/0), `mount` (mount point for the kit volume when the sysroot
/// is absent); upper-case keys (e.g. `MCL_DS_FLAG=1`) are environment defaults for the guest.
fn auto_options(conf: &str) -> Vec<String> {
    let text = std::fs::read_to_string(conf).unwrap_or_else(|e| fail(&format!("{conf}: {e}")));
    let (mut opts, mut sysroot, mut mount) = (Vec::new(), None, None);
    for line in text.lines().map(str::trim).filter(|l| !l.is_empty() && !l.starts_with('#')) {
        let Some((k, v)) = line.split_once('=') else { fail(&format!("{conf}: bad line: {line}")) };
        let (k, v) = (k.trim(), v.trim());
        match k {
            "sysroot" => sysroot = Some(v.to_string()),
            "dyld" => opts.extend(["--dyld".to_string(), v.to_string()]),
            "gpu" => {
                if v == "1" {
                    opts.push("--gpu".into());
                }
            }
            "mount" => mount = Some(v.to_string()),
            _ if k.chars().next().is_some_and(|c| c.is_ascii_uppercase()) => {
                if std::env::var_os(k).is_none() {
                    std::env::set_var(k, v);
                }
            }
            _ => fail(&format!("{conf}: unknown key {k}")),
        }
    }
    if let Some(s) = sysroot {
        if !std::path::Path::new(&s).is_dir() {
            match &mount {
                Some(mp) => mount_kit(mp, &s),
                None => fail(&format!("sysroot {s} not found and no mount= in {conf}")),
            }
        }
        opts.extend(["--sysroot".to_string(), s]);
    }
    opts
}

/// Mount the kit volume read-only at `mp` until `want` appears: GG's diskutil cannot find it by
/// UUID (boot 57), so try each APFS slice in turn, as gg-revisiond.sh does.
// One prober at a time (boot 93: concurrent execs unmounted each other's probes): flock a lock file,
// then recheck `want`, since the holder before us may have mounted it. The lock drops at exit/exec.
fn mount_kit(mp: &str, want: &str) {
    let _ = std::fs::create_dir_all(mp);
    use std::os::unix::io::AsRawFd;
    let lock = std::fs::OpenOptions::new().create(true).write(true).open("/var/run/maclator-mount.lock");
    if let Ok(f) = &lock {
        unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_EX) };
        if std::path::Path::new(want).is_dir() {
            return;
        }
    }
    let mut devs: Vec<String> = std::fs::read_dir("/dev")
        .map(|d| d.filter_map(|e| e.ok()?.file_name().into_string().ok()).collect())
        .unwrap_or_default();
    devs.retain(|n| n.starts_with("disk") && n[4..].contains('s'));
    devs.sort();
    for dv in devs {
        if std::path::Path::new(want).is_dir() {
            return;
        }
        let ok = std::process::Command::new("/sbin/mount_apfs")
            .args(["-o", "rdonly", &format!("/dev/{dv}"), mp])
            .stderr(std::process::Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if ok && !std::path::Path::new(want).is_dir() {
            let _ = std::process::Command::new("/sbin/umount").arg(mp).status();
        }
    }
    if !std::path::Path::new(want).is_dir() {
        fail(&format!("sysroot {want} not found on any APFS slice"));
    }
}

fn resolve_path(p: &str) -> String {
    if p.contains('/') {
        return std::fs::canonicalize(p).map(|x| x.to_string_lossy().into_owned()).unwrap_or_else(|_| p.to_string());
    }
    if let Ok(path) = std::env::var("PATH") {
        for dir in path.split(':') {
            let cand = format!("{dir}/{p}");
            if std::path::Path::new(&cand).is_file() {
                return std::fs::canonicalize(&cand).map(|x| x.to_string_lossy().into_owned()).unwrap_or(cand);
            }
        }
    }
    p.to_string()
}
