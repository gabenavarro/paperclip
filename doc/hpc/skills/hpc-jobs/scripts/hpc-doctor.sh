#!/usr/bin/env bash
# Checks that this box is ready for HPC agents. Prints PASS/FAIL lines; exits 1 on any FAIL.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

fails=0
check() {
  local name="$1" out
  shift
  if out=$("$@" 2>&1); then
    printf 'PASS %s %s\n' "$name" "$(head -n1 <<<"$out")"
  else
    printf 'FAIL %s %s\n' "$name" "$(head -n1 <<<"$out")"
    fails=$((fails + 1))
  fi
}

check slurm-gpu bash -c 'sinfo -h -o "%G" | grep gpu'
check nvidia-driver nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader
check apptainer apptainer --version
check podman-rootless bash -c 'test "$(podman info --format "{{.Host.Security.Rootless}} {{.Store.GraphDriverName}}")" = "true overlay"'
check nextflow bash -c '[ -n "${NXF_VER:-}" ] && nextflow -version | grep -o "version [0-9.]*"'
check jobs-dir test -w "$HPC_JOBS_ROOT"
check refs-dir test -r "$HPC_REFS_ROOT"
check images-dir test -w "$HPC_IMAGES_ROOT"
for tool in node git tar curl jq claude; do check "tool-$tool" command -v "$tool"; done
if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
  check gcp-credentials bash -c '[ "$(stat -c %a "$GOOGLE_APPLICATION_CREDENTIALS")" = 600 ] && echo "mode 600"'
fi
if [[ $fails -gt 0 ]]; then printf '%s check(s) failed\n' "$fails"; exit 1; fi
printf 'all checks passed\n'
