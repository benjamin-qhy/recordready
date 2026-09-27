use std::{env, path::PathBuf, process::Command};

fn main() {
    if env::var("CARGO_CFG_TARGET_OS").unwrap() == "macos" {
        let out = PathBuf::from(env::var("OUT_DIR").unwrap());
        let target = env::var("TARGET").unwrap();
        let swift_target = if target.starts_with("aarch64") { "arm64-apple-macosx13.0" } else { "x86_64-apple-macosx13.0" };
        let sparkle = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap()).join("../vendor/sparkle");
        let output = Command::new("xcrun").args(["swiftc", "-swift-version", "5", "-O", "-parse-as-library", "-emit-library", "-static", "-module-name", "RecordReadyNative", "-target", swift_target, "-F", sparkle.to_str().unwrap(), "../native/UpdatePolicy.swift", "../native/Updater.swift", "../native/BeautyEffects.swift", "../native/CaptureEngine.swift", "../native/Bridge.swift", "-o"])
            .arg(out.join("libRecordReadyNative.a")).output().expect("Swift compiler required");
        if !output.status.success() { panic!("{}", String::from_utf8_lossy(&output.stderr)); }
        println!("cargo:rerun-if-changed=../native");
        println!("cargo:rerun-if-changed=../vendor/sparkle/provenance.json");
        if !sparkle.join("Sparkle.framework").exists() { panic!("Run bun scripts/release/prepare-sparkle.ts before building"); }
        println!("cargo:rustc-link-search=framework={}", sparkle.display());
        println!("cargo:rustc-link-lib=framework=Sparkle");
        println!("cargo:rustc-link-arg=-Wl,-rpath,@executable_path/../Frameworks");
        if env::var("PROFILE").unwrap() == "debug" { println!("cargo:rustc-link-arg=-Wl,-rpath,{}", sparkle.display()); }
        println!("cargo:rustc-link-search=native={}", out.display());
        println!("cargo:rustc-link-lib=static=RecordReadyNative");
        let info = Command::new("xcrun").args(["swiftc", "-print-target-info"]).output().unwrap();
        let info: serde_json::Value = serde_json::from_slice(&info.stdout).unwrap();
        for path in info["paths"]["runtimeLibraryPaths"].as_array().unwrap() {
            println!("cargo:rustc-link-search=native={}", path.as_str().unwrap());
        }
        println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");
        for framework in ["AppKit", "AVFoundation", "ScreenCaptureKit", "CoreMedia", "CoreVideo", "Foundation", "QuartzCore", "AudioToolbox", "Vision", "CoreImage", "Metal", "MetalKit"] {
            println!("cargo:rustc-link-lib=framework={framework}");
        }
        println!("cargo:rustc-link-lib=dylib=swiftCore");
        println!("cargo:rustc-link-lib=dylib=swift_Concurrency");
    }
    tauri_build::build()
}
