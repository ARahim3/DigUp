fn main() {
    // The pages are embedded at compile time; without this a change to them alone wouldn't rebuild the app.
    println!("cargo:rerun-if-changed=../ui");
    tauri_build::build()
}
