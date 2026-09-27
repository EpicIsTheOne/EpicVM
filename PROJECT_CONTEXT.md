# EpicVM Project Context

- **Product:** EpicVM VM platform
- **Status:** active
- **Current repository:** https://github.com/EpicIsTheOne/EpicVM
- **Repository status:** independent EpicVM repository, separate from the original BlobeVM fork.

## Purpose

EpicVM is a Docker-based VM platform with a web dashboard and CLI for creating, routing, monitoring, and maintaining isolated desktop VMs. EpicVM expanded on the original project created by [Blobby-Boi](https://github.com/Blobby-Boi/). It remains under the GNU General Public License version 3 (GPLv3); see `LICENSE` for the complete license text and preserve upstream attribution.

## Stack

- Docker-based VM lifecycle management
- EpicVM Dashboard (legacy and modern UI routes)
- VM routing through Traefik or direct high-port mode
- VM-focused optimizer components
- Shell and Python installation tooling

## Compatibility contract

Existing deployments continue to use the legacy ABI: `blobe-vm-manager`, `install-blobevm.sh`, `/opt/blobe-vm`, `blobevm_<name>` container names, `BLOBEVM_*` variables, service IDs `blobedash` and `blobe-optimizer`, and established routes such as `/dashboard`, `/Dashboard`, and `/vm/<name>/`. These identifiers are retained for compatibility; new public-facing documentation uses EpicVM and `epicvm`.
