use std::path::PathBuf;
use std::process::Command;

fn main() {
    // APP_BUNDLE_ID is read with option_env!, so without this a changed value
    // would be baked into a stale binary.
    println!("cargo:rerun-if-env-changed=APP_BUNDLE_ID");
    println!("cargo:rerun-if-env-changed=APP_GROUP_ID");
    println!("cargo:rerun-if-changed=widget/WidgetBridge.swift");

    // SMAppService, for the login item. Linked rather than looked up through the
    // runtime because the bundle targets macOS 13, where the class is always
    // there. A build script runs on the host, so ask Cargo about the target.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        println!("cargo:rustc-link-lib=framework=ServiceManagement");
        println!("cargo:rustc-link-lib=framework=WidgetKit");
        compile_widget_bridge();
    }
}

/// WidgetCenter is a Swift-only API. Compile one C-callable function into an
/// object and hand it to rustc, which keeps the app as a single executable and
/// avoids shipping a helper process or framework.
fn compile_widget_bridge() {
    let arch = match std::env::var("CARGO_CFG_TARGET_ARCH").as_deref() {
        Ok("aarch64") => "arm64",
        Ok("x86_64") => "x86_64",
        Ok(other) => panic!("unsupported macOS architecture for widget bridge: {other}"),
        Err(err) => panic!("could not read widget bridge target architecture: {err}"),
    };
    let out_dir = PathBuf::from(std::env::var_os("OUT_DIR").expect("OUT_DIR is not set"));
    let object = out_dir.join("WidgetBridge.o");
    let sdk = Command::new("xcrun")
        .args(["--sdk", "macosx", "--show-sdk-path"])
        .output()
        .expect("could not run xcrun for the macOS SDK");
    if !sdk.status.success() {
        panic!(
            "xcrun could not find the macOS SDK: {}",
            String::from_utf8_lossy(&sdk.stderr)
        );
    }
    let sdk = String::from_utf8(sdk.stdout)
        .expect("macOS SDK path was not UTF-8")
        .trim()
        .to_string();
    let target = format!("{arch}-apple-macosx13.0");
    let built = Command::new("xcrun")
        .args([
            "swiftc",
            "-parse-as-library",
            "-emit-object",
            "-module-name",
            "ClaudeUsageWidgetBridge",
            "-sdk",
            &sdk,
            "-target",
            &target,
            "-o",
        ])
        .arg(&object)
        .arg("widget/WidgetBridge.swift")
        .output()
        .expect("could not run swiftc for the widget bridge");
    if !built.status.success() {
        panic!(
            "could not compile widget bridge: {}",
            String::from_utf8_lossy(&built.stderr)
        );
    }
    println!("cargo:rustc-link-arg={}", object.display());
}
