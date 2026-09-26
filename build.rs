//! Builds the Kizu core (satin-kizu) into one object and links it into this
//! crate, so the static library, the binaries and the tests all carry it.
//! One object holds every Kizu module: each object brings the Kizu runtime,
//! and a link takes it once.

use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let kizu = env::var("KIZU").unwrap_or_else(|_| "kizu".to_owned());
    let manifest =
        PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("cargo sets CARGO_MANIFEST_DIR"));
    let source = env::var("SATIN_KIZU_CORE")
        .map(PathBuf::from)
        .unwrap_or_else(|_| manifest.join("../satin-kizu"));
    let out = PathBuf::from(env::var("OUT_DIR").expect("cargo sets OUT_DIR"));
    let object = out.join("satin_kizu.o");
    let status = Command::new(&kizu)
        .args([
            "build", "--target", "native", "--emit", "obj", "--opt", "-o",
        ])
        .arg(&object)
        .arg(&source)
        .status()
        .unwrap_or_else(|error| panic!("run {kizu}: {error}"));
    assert!(
        status.success(),
        "{kizu} could not build {}",
        source.display()
    );
    let archive = out.join("libsatin_kizu.a");
    let _ = std::fs::remove_file(&archive);
    let status = Command::new("ar")
        .arg("rcs")
        .arg(&archive)
        .arg(&object)
        .status()
        .expect("run ar");
    assert!(
        status.success(),
        "ar could not archive {}",
        object.display()
    );
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=satin_kizu");
    println!("cargo:rerun-if-env-changed=KIZU");
    println!("cargo:rerun-if-env-changed=KIZU_LIB_DIR");
    println!("cargo:rerun-if-env-changed=SATIN_KIZU_CORE");
    println!("cargo:rerun-if-changed={}", source.join("src").display());
    println!(
        "cargo:rerun-if-changed={}",
        source.join("kizu.toml").display()
    );
}
