fn main() {
    // APP_BUNDLE_ID is read with option_env!, so without this a changed value
    // would be baked into a stale binary.
    println!("cargo:rerun-if-env-changed=APP_BUNDLE_ID");

    // SMAppService, for the login item. Linked rather than looked up through the
    // runtime because the bundle targets macOS 13, where the class is always
    // there. A build script runs on the host, so ask Cargo about the target.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        println!("cargo:rustc-link-lib=framework=ServiceManagement");
    }
}
