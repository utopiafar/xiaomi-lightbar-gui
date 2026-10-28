#![cfg_attr(target_os = "windows", windows_subsystem = "windows")]

use std::ffi::OsStr;
use std::path::PathBuf;
use std::process::{Command, ExitCode};
use std::time::Duration;

fn cache_root() -> PathBuf {
    if let Some(override_dir) = std::env::var_os("LIGHTBAR_LAUNCHER_CACHE") {
        return PathBuf::from(override_dir);
    }
    let local = std::env::var_os("LOCALAPPDATA")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    local.join("XiaomiLightbar").join("runtime")
}

fn run() -> Result<(), String> {
    let executable = std::env::current_exe().map_err(|e| format!("无法找到程序文件：{e}"))?;
    let payload = lightbar_launcher::read_payload(&executable)?;
    let installed = lightbar_launcher::prepare_cache(&cache_root(), &payload)?;
    let argument = std::env::args_os().nth(1);
    if argument.as_deref() == Some(OsStr::new("--verify-only")) {
        return Ok(());
    }
    let mut command = Command::new(installed.join("xiaomi_lightbar_desktop.exe"));
    command
        .current_dir(&installed)
        .env("LIGHTBAR_SINGLE_EXE", &executable);
    let mut child = command
        .spawn()
        .map_err(|e| format!("无法启动控制面板：{e}"))?;
    if argument.as_deref() == Some(OsStr::new("--smoke-test")) {
        for _ in 0..50 {
            if let Some(status) = child.try_wait().map_err(|e| e.to_string())? {
                return Err(format!("控制面板启动后意外退出：{status}"));
            }
            std::thread::sleep(Duration::from_millis(200));
        }
        child.kill().map_err(|e| e.to_string())?;
        let _ = child.wait();
    }
    Ok(())
}

#[cfg(windows)]
fn show_error(message: &str) {
    use std::ffi::c_void;
    #[link(name = "user32")]
    extern "system" {
        fn MessageBoxW(
            window: *mut c_void,
            text: *const u16,
            caption: *const u16,
            flags: u32,
        ) -> i32;
    }
    let text: Vec<u16> = message.encode_utf16().chain(Some(0)).collect();
    let caption: Vec<u16> = "小米挂灯控制".encode_utf16().chain(Some(0)).collect();
    // MB_OK | MB_ICONERROR; no other Windows resources are needed.
    unsafe { MessageBoxW(std::ptr::null_mut(), text.as_ptr(), caption.as_ptr(), 0x10) };
}

#[cfg(not(windows))]
fn show_error(message: &str) {
    eprintln!("{message}");
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            if let Some(path) = std::env::var_os("LIGHTBAR_LAUNCHER_DIAGNOSTIC") {
                let _ = std::fs::write(path, &error);
            }
            let argument = std::env::args_os().nth(1);
            if matches!(argument.as_deref(), Some(value) if value == OsStr::new("--verify-only") || value == OsStr::new("--smoke-test"))
            {
                eprintln!("{error}");
            } else {
                show_error(&error);
            }
            ExitCode::FAILURE
        }
    }
}
