//! Which local serial adapters are plugged in *right now*.
//!
//! Discovery can only find the grid meter if it is offered every port. When
//! the only candidate is the configured path, a meter whose adapter died on
//! the USB bus (measured 2026-11-27: the FT232R carrying it enumerated *off*
//! fourteen seconds after discovery had confirmed it as the meter) leaves the
//! relay pinned to a device that no longer exists, dialling it forever.
//!
//! So this module lists the kernel's stable handles (`/dev/serial/by-id`,
//! `/dev/serial/by-path`), deduplicates them by the device they actually
//! resolve to — the same port appears in both directories, and an adapter
//! without a serial number shares one `by-id` name with any identical twin —
//! and skips the ones the exclusion list claims.
//!
//! The exclusion list is load-bearing, not cosmetic: `/dev/otbr-rcp` is the
//! Thread border router's radio on grafton-router
//! (`hosts/grafton-router/services/otbr.nix`, a udev rule naming the stick by
//! its unique serial). otbr-agent actively reads and writes that port, and
//! opening it to fire a Modbus probe would eat frames belonging to the mesh.
//! An entry is matched as a path against the device it resolves to — so the
//! entry follows the link across radio swaps and never names an adapter that
//! may one day be the meter — or, if it contains `*`, as a glob over the
//! whole path.

use std::fs;
use std::path::{Component, Path, PathBuf};

use crate::endpoint::Endpoint;

/// Ports under `dirs` that are neither excluded nor already offered in
/// `already`, in directory order and then name order (`by-id` first: the
/// stable names are the ones worth reading first on the diagnostics page).
/// Every entry is a symlink to a device node; one whose target has vanished
/// is skipped — a device that is not on the bus can answer nothing, and its
/// dead name is noise in a report about what is here now.
pub fn candidates(
    dirs: &[PathBuf],
    baud: u32,
    exclude: &[String],
    already: &[Endpoint],
) -> Vec<Endpoint> {
    let mut out: Vec<Endpoint> = Vec::new();
    // Only *live* identities deduplicate: a configured path that is stale
    // right now (the classic case: a `/dev/ttyUSBn` name whose adapter is
    // gone) must not veto a different adapter that the kernel later names
    // the same node.
    let mut offered: Vec<PathBuf> = already
        .iter()
        .filter_map(|endpoint| match endpoint {
            Endpoint::Serial { path, .. } => fs::canonicalize(path).ok(),
            Endpoint::Tcp { .. } => None,
        })
        .collect();

    for dir in dirs {
        let Ok(entries) = fs::read_dir(dir) else {
            continue; // the directory itself may not exist on this kernel
        };
        let mut paths: Vec<PathBuf> = entries
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| fs::metadata(path).is_ok()) // a live device behind the link
            .collect();
        paths.sort();

        for path in paths {
            let Some(device) = fs::canonicalize(&path).ok() else {
                continue; // vanished between the listing and now
            };
            if offered.contains(&device) || excluded(&path, exclude) {
                continue;
            }
            offered.push(device);
            out.push(Endpoint::serial(path.display().to_string(), baud));
        }
    }
    out
}

/// Whether the exclusion list names this device path: by the device it
/// resolves to, or by glob.
pub fn excluded(path: &Path, patterns: &[String]) -> bool {
    patterns.iter().any(|pattern| {
        if pattern.contains('*') {
            glob_match(pattern, &path.display().to_string())
        } else {
            let other = Path::new(pattern);
            other == path
                || match (identity(other), identity(path)) {
                    (Some(one), Some(other)) => one == other,
                    _ => false,
                }
        }
    })
}

/// The device a symlink names — answered even when the adapter is not on
/// the bus, because a dangling link still records which node it pointed to.
/// That is what lets an exclusion name a radio during the seconds between
/// unplugging it and its replacement appearing; for a link udev creates per
/// device, gone means gone, and such an exclusion is inert rather than
/// wrongly vetoing whatever reuses the node.
fn identity(path: &Path) -> Option<PathBuf> {
    match fs::canonicalize(path) {
        Ok(real) => Some(real),
        Err(_) => {
            let target = fs::read_link(path).ok()?;
            let joined = if target.is_relative() {
                path.parent()?.join(target)
            } else {
                target
            };
            Some(lexically_normalize(&joined))
        }
    }
}

/// Collapses `.` and `..` textually, because the target of a dangling link
/// cannot be resolved against the filesystem.
fn lexically_normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::ParentDir => {
                if !out.pop() {
                    // Ran off the root: hand back the raw form rather than a
                    // confidently wrong answer.
                    return path.to_path_buf();
                }
            }
            Component::CurDir => {}
            other => out.push(other),
        }
    }
    out
}

/// `*` matches any run of characters (including `/`); everything else is a
/// literal. Cheap backtracking: these are path lengths, not document lengths.
fn glob_match(pattern: &str, text: &str) -> bool {
    let Some((prefix, rest)) = pattern.split_once('*') else {
        return pattern == text;
    };
    let Some(tail) = text.strip_prefix(prefix) else {
        return false;
    };
    tail.char_indices()
        .map(|(index, _)| index)
        .chain(std::iter::once(tail.len()))
        .any(|skip| glob_match(rest, &tail[skip..]))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A stand-in for `/dev/serial`: the "device nodes" are empty files, the
    /// directory entries are relative symlinks, exactly as udev lays them
    /// out. Each test gets its own root so they never see each other's
    /// adapters.
    struct Fixture {
        root: PathBuf,
    }

    impl Fixture {
        fn new(name: &str) -> Self {
            let root = std::env::temp_dir()
                .join(format!("meter-relay-serial-{}-{name}", std::process::id()));
            let _ = fs::remove_dir_all(&root);
            fs::create_dir_all(root.join("by-id")).unwrap();
            fs::create_dir_all(root.join("by-path")).unwrap();
            Self { root }
        }

        /// A device node that is "on the bus".
        fn node(&self, name: &str) {
            fs::write(self.root.join(name), b"").unwrap();
        }

        fn link(&self, dir: &str, entry: &str, target: &str) -> PathBuf {
            let link = self.root.join(dir).join(entry);
            std::os::unix::fs::symlink(self.root.join(target), &link).unwrap();
            link
        }

        fn dirs(&self) -> Vec<PathBuf> {
            vec![self.root.join("by-id"), self.root.join("by-path")]
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn every_live_port_is_offered_once_by_id_first_and_never_the_dead_ones() {
        let fixture = Fixture::new("enumerate");
        fixture.node("ttyA");
        fixture.node("ttyB");
        fixture.node("ttyC");
        fixture.link("by-id", "usb-A", "ttyA");
        fixture.link("by-id", "usb-B", "ttyB");
        // The same port again, by socket; another port only the socket path
        // names; and an adapter that left the bus, whose dead link must not
        // become a candidate.
        fixture.link("by-path", "pci-A", "ttyA");
        fixture.link("by-path", "pci-C", "ttyC");
        fixture.link("by-path", "pci-Gone", "ttyGone");

        let found = candidates(&fixture.dirs(), 9600, &[], &[]);
        let named = |dir: &str, name: &str| {
            Endpoint::serial(
                fixture.root.join(dir).join(name).display().to_string(),
                9600,
            )
        };
        // pci-A resolved to the same device as usb-A, so it is offered once —
        // and the expected list spells the order too: by-id names first.
        assert_eq!(
            found,
            vec![
                named("by-id", "usb-A"),
                named("by-id", "usb-B"),
                named("by-path", "pci-C")
            ]
        );
    }

    #[test]
    fn an_exclusion_names_the_device_a_link_resolves_to_not_its_name() {
        let fixture = Fixture::new("exclude-identity");
        fixture.node("ttyRadio");
        fixture.node("ttyMeter");
        fixture.link("by-id", "usb-Radio", "ttyRadio");
        fixture.link("by-id", "usb-Meter", "ttyMeter");
        // The otbr situation: the service's own stable link names the radio.
        fixture.link("by-path", "irrelevant", "ttyRadio");
        let rcp = fixture.root.join("rcp");
        std::os::unix::fs::symlink(fixture.root.join("ttyRadio"), &rcp).unwrap();

        let exclude = vec![rcp.display().to_string()];
        let found = candidates(&fixture.dirs(), 9600, &exclude, &[]);
        assert_eq!(found.len(), 1, "{found:?}");
        assert!(found[0].to_string().contains("usb-Meter"), "{found:?}");
    }

    #[test]
    fn enumeration_adds_what_the_configuration_did_not_name_and_duplicates_nothing() {
        let fixture = Fixture::new("enumerate-extra");
        fixture.node("ttyFresh");
        fixture.link("by-id", "usb-Fresh", "ttyFresh");

        // The 2026-11-27 case: the configured path's adapter is gone (the
        // kernel removed the by-id entry with it), and the meter has moved
        // to an adapter nobody named — the live port must still be offered.
        let gone = fixture.root.join("ttyGone");
        let already = vec![Endpoint::serial(gone.display().to_string(), 9600)];
        let found = candidates(&fixture.dirs(), 9600, &[], &already);
        assert_eq!(found.len(), 1, "{found:?}");
        assert!(found[0].to_string().contains("usb-Fresh"), "{found:?}");

        // A configured path that *is* a live port is not offered twice.
        let found = candidates(&fixture.dirs(), 9600, &[], &found);
        assert!(found.is_empty(), "{found:?}");
    }

    #[test]
    fn a_glob_excludes_by_path() {
        let fixture = Fixture::new("exclude-glob");
        fixture.node("ttyRadio");
        fixture.node("ttyMeter");
        fixture.link("by-id", "usb-Radio", "ttyRadio");
        fixture.link("by-id", "usb-Meter", "ttyMeter");

        let exclude = vec![format!("{}*usb-Radio", fixture.root.display())];
        let found = candidates(&fixture.dirs(), 9600, &exclude, &[]);
        assert_eq!(found.len(), 1, "{found:?}");
        assert!(found[0].to_string().contains("usb-Meter"), "{found:?}");
    }

    #[test]
    fn globs_match_any_run_including_path_separators() {
        assert!(glob_match(
            "*Sonoff*",
            "/dev/serial/by-id/usb-ITead_Sonoff_x-if00-port0"
        ));
        assert!(glob_match("/dev/serial/by-id/*", "/dev/serial/by-id/usb-A"));
        assert!(!glob_match(
            "/dev/serial/by-id/*",
            "/dev/serial/by-path/pci-A"
        ));
        assert!(glob_match("*", "/anything"));
        assert!(glob_match("a*b*c", "aXbXc"));
        assert!(
            glob_match("a*b*c", "abbc"),
            "\"*\" may consume the second b"
        );
        assert!(!glob_match("a*b*c", "acb"), "the literal b must appear");
        assert!(!glob_match("exact", "/with/prefix/exact"));
    }
}
