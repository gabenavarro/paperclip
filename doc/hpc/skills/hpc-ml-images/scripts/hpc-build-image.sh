#!/usr/bin/env bash
# Builds a Dockerfile with rootless Podman and stores it as a pinned Apptainer image.
# Usage: bash scripts/hpc-build-image.sh NAME TAG CONTEXT_DIR
set -euo pipefail
HPC_IMAGES_ROOT="${HPC_IMAGES_ROOT:-/data/images}"
die() { printf 'error: %s\n' "$*" >&2; exit 2; }

[[ $# -eq 3 ]] || die "usage: hpc-build-image.sh NAME TAG CONTEXT_DIR"
name="$1" tag="$2" context="$3"
[[ "$name" =~ ^[a-z0-9][a-z0-9._-]*$ && "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
  die "name (lowercase) and tag may use letters, digits, '.', '_' and '-'"
[[ -f "$context/Dockerfile" ]] || die "no Dockerfile in $context"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
podman build -t "localhost/$name:$tag" "$context"
podman save -o "$tmp/image.tar" "localhost/$name:$tag"
apptainer build "$tmp/image.sif" "docker-archive:$tmp/image.tar"
sha=$(sha256sum "$tmp/image.sif" | cut -c1-12)
dest="$HPC_IMAGES_ROOT/$name/$tag-$sha.sif"
mkdir -p "$(dirname "$dest")"
mv "$tmp/image.sif" "$dest"
printf 'image: %s\n' "$dest"
apptainer inspect --labels "$dest" || true
