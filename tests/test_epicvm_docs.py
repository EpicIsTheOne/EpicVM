from pathlib import Path


REPO_ROOT = Path(__file__).parents[1]
DOCS = [
    REPO_ROOT / "README.md",
    REPO_ROOT / "PROJECT_CONTEXT.md",
    REPO_ROOT / "docs/CLI.md",
    REPO_ROOT / "docs/DASHBOARD_V2.md",
    REPO_ROOT / "docs/DEVELOPMENT.md",
]


def combined_docs():
    return "\n".join(path.read_text() for path in DOCS)


def test_public_docs_present_epicvm_product_identity_and_commands():
    text = combined_docs()
    for value in ("EpicVM", "epicvm", "install-epicvm.sh", "EpicVM Dashboard"):
        assert value in text
    assert "https://raw.githubusercontent.com/EpicIsTheOne/EpicVM/main/install-epicvm.sh | sudo bash" in text
    assert "epicvm doctor" in text
    assert "?v=" not in text


def test_public_docs_define_legacy_compatibility_abi():
    text = combined_docs()
    for value in (
        "blobe-vm-manager",
        "install-blobevm.sh",
        "/opt/blobe-vm",
        "blobevm_<name>",
        "BLOBEVM_",
        "blobedash",
        "blobe-optimizer",
        "legacy ABI",
    ):
        assert value in text
    assert "existing deployments" in text


def test_public_docs_preserve_license_and_upstream_attribution():
    text = combined_docs()
    assert "GNU General Public License" in text or "GPLv3" in text
    assert "DesktopOnCodespaces" in text
    assert "https://github.com/Blobby-Boi/" in text
    assert "https://github.com/EpicIsTheOne/EpicVM" in text


def test_docs_keep_epicvm_scope_and_avoid_generic_admin_claims():
    text = combined_docs().lower()
    assert "vm platform" in text
    assert "cockpit" not in text
    assert "generic server administration" not in text
