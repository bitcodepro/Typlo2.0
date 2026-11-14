#![cfg_attr(windows, windows_subsystem = "windows")]

// Preserve the existing Unix target. Cargo checks this target on Windows too,
// but it is unsupported there and is never part of a Windows release package.
#[cfg(not(windows))]
#[path = "../resident_cli.rs"]
mod resident_cli;

#[cfg(not(windows))]
fn main() {
    resident_cli::main();
}

#[cfg(windows)]
fn main() {
    eprintln!("typlo-rust is a Unix target. Run Typlo.exe on Windows.");
    std::process::exit(1);
}
