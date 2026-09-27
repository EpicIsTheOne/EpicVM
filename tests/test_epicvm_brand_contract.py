"""Executable contract checks for EpicVM's public brand and compatibility ABI."""

from __future__ import annotations

from pathlib import Path
import re
import subprocess


REPO_ROOT = Path(__file__).resolve().parents[1]
ALLOWLIST_PATH = REPO_ROOT / "tests" / "brand_legacy_allowlist.txt"
LEGACY_ABI_TOKENS = (
    "/opt/blobe-vm",
    "blobevm_",
    "com.blobevm.managed",
    "BLOBEVM_",
    "BLOBEDASH_",
)

# These are the public-facing files in scope for the initial rebrand contract.
# EpicVM.txt is the intended destination; the legacy filename remains in scope
# until the later task performs the rename.
PUBLIC_FILES = (
    "README.md",
    "PROJECT_CONTEXT.md",
    "dashboard/app.py",
    "dashboard_v2/index.html",
    "dashboard_v2/src/components/Login.jsx",
    "dashboard_v2/src/components/Sidebar.jsx",
    "dashboard_v2/src/components/Topbar.jsx",
    "root/config/Desktop/EpicVM.txt",
)

_LOCKFILE_NAME = re.compile(r"(?:^|[-_.])lock(?:file)?(?:[-_.]|$)", re.IGNORECASE)
_HISTORICAL_MARKERS = ("rollback", "history", "historical", "archive", "archived")
_BINARY_SUFFIXES = {
    ".7z",
    ".avif",
    ".bin",
    ".bmp",
    ".class",
    ".dll",
    ".eot",
    ".exe",
    ".gif",
    ".gz",
    ".ico",
    ".jar",
    ".jpeg",
    ".jpg",
    ".lockb",
    ".mov",
    ".mp3",
    ".mp4",
    ".otf",
    ".pdf",
    ".png",
    ".pyc",
    ".rar",
    ".so",
    ".tar",
    ".tgz",
    ".ttf",
    ".wav",
    ".webp",
    ".woff",
    ".woff2",
    ".zip",
}


def _tracked_files() -> list[Path]:
    """Return tracked paths, making the test independent of cwd/package install."""
    result = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "ls-files", "-z"],
        check=True,
        capture_output=True,
    )
    return [REPO_ROOT / item for item in result.stdout.decode().split("\0") if item]


def _human_facing_source_files() -> list[Path]:
    """Select tracked text sources while excluding generated/history artifacts."""
    excluded_parts = {".git", ".hermes", "dist", "screenshots"}
    files = []
    for path in _tracked_files():
        relative = path.relative_to(REPO_ROOT)
        parts_lower = tuple(part.lower() for part in relative.parts)
        if any(part in excluded_parts for part in parts_lower):
            continue
        if _LOCKFILE_NAME.search(path.name):
            continue
        if any(marker in part for part in parts_lower for marker in _HISTORICAL_MARKERS):
            continue
        if path.suffix.lower() in _BINARY_SUFFIXES:
            continue
        try:
            contents = path.read_bytes()
        except OSError:
            continue
        if b"\0" in contents:
            continue
        try:
            contents.decode("utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        files.append(path)
    return files


def _allowlist_entries() -> dict[str, str]:
    entries = {}
    for raw_line in ALLOWLIST_PATH.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        token, separator, reason = line.partition("|")
        assert separator, f"Malformed allowlist line: {raw_line!r}"
        entries[token.strip()] = reason.strip()
    return entries


def test_legacy_abi_tokens_are_documented_with_reasons() -> None:
    entries = _allowlist_entries()
    assert set(LEGACY_ABI_TOKENS) <= entries.keys()
    for token in LEGACY_ABI_TOKENS:
        assert entries[token], f"Missing compatibility reason for {token!r}"


def test_current_public_files_contain_no_legacy_public_brand() -> None:
    """Reject legacy product copy outside documented compatibility tokens."""
    violations = []
    for relative in PUBLIC_FILES:
        path = REPO_ROOT / relative
        if not path.is_file():
            violations.append(f"{relative}: missing required public file")
            continue
        text = path.read_text(encoding="utf-8")
        for line_number, line in enumerate(text.splitlines(), start=1):
            if "BlobeVM" in line:
                violations.append(f"{relative}:{line_number}: {line.strip()}")
    assert not violations, "Visible legacy public-brand uses:\n" + "\n".join(violations)
