fn main() {
    // APP_BUNDLE_ID is read with option_env!, so without this a changed value
    // would be baked into a stale binary.
    println!("cargo:rerun-if-env-changed=APP_BUNDLE_ID");
}
