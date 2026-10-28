use fs2::FileExt;
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Cursor, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};
use zip::ZipArchive;

const MAGIC: &[u8; 16] = b"LIGHTBAR_SFX_V1!";
const FOOTER_SIZE: u64 = 8 + 32 + 16;
const MAX_ARCHIVE_SIZE: u64 = 512 * 1024 * 1024;
const MAX_UNPACKED_SIZE: u64 = 1024 * 1024 * 1024;
const MAX_FILES: usize = 10_000;
const MARKER: &str = ".lightbar-bundle-sha256";
const REQUIRED: &[&str] = &[
    "xiaomi_lightbar_desktop.exe",
    "lightbar_core.dll",
    "flutter_windows.dll",
    "cnativeapi.dll",
    "data/icudtl.dat",
    "data/flutter_assets/AssetManifest.bin",
];
static STAGING_COUNTER: AtomicU64 = AtomicU64::new(0);

pub struct Payload {
    pub bytes: Vec<u8>,
    pub hash: String,
}

/// Read the ZIP appended after the PE image and reject incomplete or altered
/// downloads before extracting or launching anything.
pub fn read_payload(executable: &Path) -> Result<Payload, String> {
    let mut file = File::open(executable).map_err(|e| format!("无法读取程序文件：{e}"))?;
    let file_size = file.metadata().map_err(|e| e.to_string())?.len();
    if file_size <= FOOTER_SIZE {
        return Err("程序包不完整".into());
    }
    file.seek(SeekFrom::End(-(FOOTER_SIZE as i64)))
        .map_err(|e| e.to_string())?;
    let mut footer = [0u8; FOOTER_SIZE as usize];
    file.read_exact(&mut footer).map_err(|e| e.to_string())?;
    if &footer[40..] != MAGIC {
        return Err("程序包格式不正确".into());
    }
    let size = u64::from_le_bytes(footer[..8].try_into().unwrap());
    if size == 0 || size > MAX_ARCHIVE_SIZE || size + FOOTER_SIZE >= file_size {
        return Err("程序包长度不正确".into());
    }
    file.seek(SeekFrom::Start(file_size - FOOTER_SIZE - size))
        .map_err(|e| e.to_string())?;
    let mut bytes = vec![0; size as usize];
    file.read_exact(&mut bytes).map_err(|e| e.to_string())?;
    let actual = Sha256::digest(&bytes);
    if actual.as_slice() != &footer[8..40] {
        return Err("程序包校验失败，请重新下载".into());
    }
    let hash = actual.iter().map(|byte| format!("{byte:02x}")).collect();
    Ok(Payload { bytes, hash })
}

fn open_archive(bytes: &[u8]) -> Result<ZipArchive<Cursor<&[u8]>>, String> {
    let archive = ZipArchive::new(Cursor::new(bytes)).map_err(|e| format!("程序包损坏：{e}"))?;
    if archive.len() > MAX_FILES {
        return Err("程序包含有过多文件".into());
    }
    Ok(archive)
}

fn safe_name(entry: &zip::read::ZipFile<'_, Cursor<&[u8]>>) -> Result<PathBuf, String> {
    let name = entry
        .enclosed_name()
        .filter(|name| !name.as_os_str().is_empty())
        .ok_or_else(|| "程序包包含无效路径".to_string())?;
    if name == Path::new(MARKER)
        || entry
            .unix_mode()
            .is_some_and(|mode| mode & 0o170000 == 0o120000)
    {
        return Err("程序包包含不受支持的文件".into());
    }
    Ok(name)
}

fn cache_complete(directory: &Path, payload: &Payload) -> bool {
    if fs::read_to_string(directory.join(MARKER)).ok().as_deref() != Some(payload.hash.as_str()) {
        return false;
    }
    if REQUIRED.iter().any(|name| !directory.join(name).is_file()) {
        return false;
    }
    let Ok(mut archive) = open_archive(&payload.bytes) else {
        return false;
    };
    for index in 0..archive.len() {
        let Ok(entry) = archive.by_index(index) else {
            return false;
        };
        let Ok(name) = safe_name(&entry) else {
            return false;
        };
        let Ok(metadata) = fs::metadata(directory.join(name)) else {
            return false;
        };
        if (entry.is_dir() && !metadata.is_dir())
            || (!entry.is_dir() && (!metadata.is_file() || metadata.len() != entry.size()))
        {
            return false;
        }
    }
    true
}

struct StagingDir(PathBuf);
impl Drop for StagingDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// Extract to a private per-user versioned cache. Staging directories are
/// published only when complete, so concurrent first launches are safe.
pub fn prepare_cache(base: &Path, payload: &Payload) -> Result<PathBuf, String> {
    fs::create_dir_all(base).map_err(|e| format!("无法创建缓存目录：{e}"))?;
    // OS-backed locking is released even after a crash. It prevents another
    // launcher from replacing or removing this version during extraction.
    let lock = OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .open(base.join(format!("{}.lock", payload.hash)))
        .map_err(|e| format!("无法锁定程序缓存：{e}"))?;
    lock.lock_exclusive()
        .map_err(|e| format!("无法锁定程序缓存：{e}"))?;
    let destination = base.join(&payload.hash);
    if cache_complete(&destination, payload) {
        return Ok(destination);
    }
    if destination.exists() {
        fs::remove_dir_all(&destination)
            .map_err(|e| format!("无法修复程序缓存，请关闭程序后重试：{e}"))?;
    }

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let sequence = STAGING_COUNTER.fetch_add(1, Ordering::Relaxed);
    let staging =
        StagingDir(base.join(format!(".extract-{}-{now}-{sequence}", std::process::id())));
    fs::create_dir(&staging.0).map_err(|e| format!("无法创建临时目录：{e}"))?;
    let mut archive = open_archive(&payload.bytes)?;
    let mut total = 0u64;
    let mut names = HashSet::new();
    for index in 0..archive.len() {
        let mut entry = archive
            .by_index(index)
            .map_err(|e| format!("读取程序包失败：{e}"))?;
        let name = safe_name(&entry)?;
        if !names.insert(name.clone()) {
            return Err("程序包包含重复文件".into());
        }
        total = total.checked_add(entry.size()).ok_or("程序包过大")?;
        if total > MAX_UNPACKED_SIZE {
            return Err("程序包过大".into());
        }
        let output = staging.0.join(name);
        if entry.is_dir() {
            fs::create_dir_all(&output).map_err(|e| format!("创建目录失败：{e}"))?;
        } else {
            if let Some(parent) = output.parent() {
                fs::create_dir_all(parent).map_err(|e| format!("创建目录失败：{e}"))?;
            }
            let mut file = File::create(output).map_err(|e| format!("创建文件失败：{e}"))?;
            io::copy(&mut entry, &mut file).map_err(|e| format!("解压程序失败：{e}"))?;
            file.flush().map_err(|e| format!("保存程序失败：{e}"))?;
        }
    }
    fs::write(staging.0.join(MARKER), &payload.hash).map_err(|e| format!("保存缓存失败：{e}"))?;
    if !cache_complete(&staging.0, payload) {
        return Err("程序包缺少必要文件".into());
    }
    match fs::rename(&staging.0, &destination) {
        Ok(()) => Ok(destination),
        Err(_) if cache_complete(&destination, payload) => Ok(destination),
        Err(error) => Err(format!("无法完成程序缓存：{error}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use zip::write::SimpleFileOptions;
    use zip::{CompressionMethod, ZipWriter};

    fn archive(extra: Option<(&str, &[u8])>) -> Vec<u8> {
        let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
        for name in REQUIRED {
            writer
                .start_file(
                    *name,
                    SimpleFileOptions::default().compression_method(CompressionMethod::Stored),
                )
                .unwrap();
            writer.write_all(b"content").unwrap();
        }
        if let Some((name, content)) = extra {
            writer
                .start_file(
                    name,
                    SimpleFileOptions::default().compression_method(CompressionMethod::Stored),
                )
                .unwrap();
            writer.write_all(content).unwrap();
        }
        writer.finish().unwrap().into_inner()
    }

    fn payload(bytes: Vec<u8>) -> Payload {
        let hash = Sha256::digest(&bytes)
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect();
        Payload { bytes, hash }
    }

    fn temporary() -> StagingDir {
        let id = STAGING_COUNTER.fetch_add(1, Ordering::Relaxed);
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = StagingDir(std::env::temp_dir().join(format!(
            "lightbar-launcher-test-{}-{now}-{id}",
            std::process::id()
        )));
        fs::create_dir_all(&directory.0).unwrap();
        directory
    }

    #[test]
    fn validates_overlay_and_detects_corruption() {
        let dir = temporary();
        let contents = archive(None);
        let hash = Sha256::digest(&contents);
        let mut exe = b"MZ-test-stub".to_vec();
        exe.extend_from_slice(&contents);
        exe.extend_from_slice(&(contents.len() as u64).to_le_bytes());
        exe.extend_from_slice(&hash);
        exe.extend_from_slice(MAGIC);
        let path = dir.0.join("test.exe");
        fs::write(&path, &exe).unwrap();
        assert_eq!(read_payload(&path).unwrap().bytes, contents);
        exe[12] ^= 1;
        fs::write(&path, exe).unwrap();
        assert!(read_payload(&path).is_err());
    }

    #[test]
    fn extracts_reuses_and_repairs_an_incomplete_cache() {
        let dir = temporary();
        let payload = payload(archive(Some(("data/example.txt", b"hello"))));
        let installed = prepare_cache(&dir.0, &payload).unwrap();
        assert_eq!(
            fs::read(installed.join("data/example.txt")).unwrap(),
            b"hello"
        );
        fs::write(installed.join("extra"), b"kept").unwrap();
        assert_eq!(prepare_cache(&dir.0, &payload).unwrap(), installed);
        assert!(installed.join("extra").exists());
        fs::write(installed.join("lightbar_core.dll"), b"truncated").unwrap();
        assert_eq!(prepare_cache(&dir.0, &payload).unwrap(), installed);
        assert_eq!(
            fs::read(installed.join("lightbar_core.dll")).unwrap(),
            b"content"
        );
    }

    #[test]
    fn rejects_parent_paths() {
        let dir = temporary();
        let payload = payload(archive(Some(("../outside.txt", b"bad"))));
        assert!(prepare_cache(&dir.0, &payload).is_err());
        assert!(!dir.0.join("outside.txt").exists());
    }

    #[test]
    fn concurrent_first_launches_publish_one_complete_cache() {
        let dir = temporary();
        let payload = std::sync::Arc::new(payload(archive(None)));
        let handles: Vec<_> = (0..4)
            .map(|_| {
                let base = dir.0.clone();
                let payload = payload.clone();
                std::thread::spawn(move || prepare_cache(&base, &payload).unwrap())
            })
            .collect();
        let paths: Vec<_> = handles
            .into_iter()
            .map(|handle| handle.join().unwrap())
            .collect();
        assert!(paths.iter().all(|path| path == &paths[0]));
        assert!(cache_complete(&paths[0], &payload));
        assert_eq!(fs::read_dir(&dir.0).unwrap().count(), 2);
    }
}
