fn main() {
    println!("cargo:rerun-if-changed=../desktop/windows/runner/resources/app_icon.ico");
    #[cfg(windows)]
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        let icon = std::path::Path::new("../desktop/windows/runner/resources/app_icon.ico")
            .canonicalize()
            .expect("application icon not found");
        let mut resource = winresource::WindowsResource::new();
        resource.set_icon(icon.to_str().expect("invalid icon path"));
        resource.set("FileDescription", "Xiaomi Lightbar Controller");
        resource
            .compile()
            .expect("failed to compile Windows launcher icon");
    }
}
