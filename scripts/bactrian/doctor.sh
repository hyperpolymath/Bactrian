#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# Bactrian dependency/readiness preflight. This command never verifies OCaml
# programs and never emits a proof receipt.
set -u

usage() {
  cat <<'EOF'
Usage: scripts/bactrian/doctor.sh [--help]

Report whether this checkout has the tools and pinned authorities needed to
start the Bactrian MVP. Exit 0 means preflight-ready only; exit 2 means blocked.
This command is not a verifier and cannot establish a proof.
EOF
}

case "${1-}" in
  --help|-h) usage; exit 0 ;;
  "") ;;
  *) printf 'error: unknown argument: %s\n' "$1" >&2; usage >&2; exit 64 ;;
esac

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
blockers=0

ok() { printf '  [ready]   %s\n' "$1"; }
missing() { printf '  [blocked] %s\n' "$1"; blockers=$((blockers + 1)); }

printf 'Bactrian MVP preflight (not a proof check)\n'
printf 'Repository: %s\n\n' "$ROOT"
printf 'Required tools:\n'
for tool in dune ocamlc why3 apalache idris2 zig dkcheck coqc lean; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool ($(command -v "$tool"))"
  else
    missing "$tool not found on PATH"
  fi
done

printf '\nECHIDNA integration:\n'
if [[ -n "${BACTRIAN_ECHIDNA_CMD-}" ]]; then
  if [[ "$BACTRIAN_ECHIDNA_CMD" == */* ]]; then
    if [[ -x "$BACTRIAN_ECHIDNA_CMD" ]]; then
      ok "configured ECHIDNA command ($BACTRIAN_ECHIDNA_CMD)"
    else
      missing "BACTRIAN_ECHIDNA_CMD is not executable: $BACTRIAN_ECHIDNA_CMD"
    fi
  elif command -v "$BACTRIAN_ECHIDNA_CMD" >/dev/null 2>&1; then
    ok "configured ECHIDNA command ($(command -v "$BACTRIAN_ECHIDNA_CMD"))"
  else
    missing "configured ECHIDNA command not found: $BACTRIAN_ECHIDNA_CMD"
  fi
else
  missing 'BACTRIAN_ECHIDNA_CMD is unset (ECHIDNA CLI/API adapter is not selected)'
fi

printf '\nCanonical authority lock syntax (this does not verify artifacts):\n'
lock="$ROOT/.machine_readable/bactrian/authorities.lock"
if [[ ! -f "$lock" ]]; then
  missing "authority lock absent: $lock"
else
  declare -A expected=()
  for name in MPR choreographic-types secret-types echo-types epistemic-types occupancy-types tropical-types ECHIDNA; do
    expected["$name"]=0
  done
  malformed=0
  while IFS=$'\t' read -r name revision digest extra || [[ -n "${name-}${revision-}${digest-}${extra-}" ]]; do
    [[ -z "${name-}" || "$name" == \#* ]] && continue
    if [[ -z "${revision-}" || -z "${digest-}" || -n "${extra-}" || ! ${expected["${name-}"]+present} ]]; then
      printf '  [blocked] malformed or unexpected lock row: %s\n' "${name-<empty>}"
      malformed=1
      continue
    fi
    if [[ "${expected[$name]}" -ne 0 ]]; then
      printf '  [blocked] duplicate authority row: %s\n' "$name"
      malformed=1
      continue
    fi
    expected["$name"]=1
    if [[ "$revision" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ && "$digest" =~ ^[0-9a-f]{64}$ ]]; then
      ok "$name pin fields populated (format only; artifact provenance is not verified)"
    elif [[ "$revision" == UNPINNED && "$digest" == UNPINNED ]]; then
      missing "$name has not been pinned to a canonical source revision and digest"
    else
      printf '  [blocked] invalid pin for %s (expected 40/64-hex revision and 64-hex digest, or UNPINNED/UNPINNED)\n' "$name"
      malformed=1
    fi
  done < "$lock"
  for name in "${!expected[@]}"; do
    if [[ "${expected[$name]}" -eq 0 ]]; then
      printf '  [blocked] missing authority row: %s\n' "$name"
      malformed=1
    fi
  done
  if [[ "$malformed" -ne 0 ]]; then
    blockers=$((blockers + 1))
  fi
fi

printf '\nImplementation scaffold:\n'
for path in dune-project src/ppx/dune src/driver/dune; do
  if [[ -f "$ROOT/$path" ]]; then
    ok "$path present"
  else
    missing "$path absent (compiler/verifier integration not implemented)"
  fi
done

printf '\n'
if [[ "$blockers" -eq 0 ]]; then
  printf 'Preflight READY: prerequisites are present. This is NOT verification and grants no proof status.\n'
  exit 0
fi
printf 'Preflight BLOCKED: %d readiness item(s) unresolved. No verification or proof status was produced.\n' "$blockers"
exit 2
