# EpicVM development and verification

EpicVM development covers the Linux Docker VM platform, its EpicVM Dashboard, and the VM-focused CLI.

## Local checks

From a Linux checkout:

```bash
python3 -m pytest tests -q
python3 -m pytest dashboard/tests -q
cd dashboard_v2
npm ci
npm run test
npm run build
cd ..
git diff --check
```

On Windows, use Git plus Node.js for the dashboard frontend and Docker Desktop with its WSL2 backend for VM runtime work. A native Windows dashboard backend is not supported.

## Public names and compatibility

Use `EpicVM`, `epicvm`, `EpicVM Dashboard`, and `install-epicvm.sh` in new product-facing copy and examples. Preserve the legacy ABI in code and operational guidance: `blobe-vm-manager`, `install-blobevm.sh`, `/opt/blobe-vm`, `blobevm_<name>` container names, `BLOBEVM_*` variables, service IDs `blobedash` and `blobe-optimizer`, and old routes such as `/dashboard`, `/Dashboard`, and `/vm/<name>/`. These identifiers remain valid for existing deployments.

## Attribution

EpicVM grew from the original project created by [Blobby-Boi](https://github.com/Blobby-Boi/) and remains licensed under the GNU General Public License version 3 (GPLv3). Preserve this attribution and the repository `LICENSE`.

The independent EpicVM repository is https://github.com/EpicIsTheOne/EpicVM.
