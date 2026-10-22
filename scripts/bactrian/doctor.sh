#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# Bactrian dependency/readiness preflight. This command never verifies OCaml
# programs and never emits a proof receipt.
set -u

# Write command usage and preflight exit-status help to stdout.
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

# Print $1 as a ready item to stdout.
ok() { printf '  [ready]   %s\n' "$1"; }
# Print $1 as a blocked item to stdout and increment the global blockers count.
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
  # Match the raw row: tab is IFS whitespace, so read would collapse empty columns.
  row_pattern=$'^([^\t]+)\t([^\t]+)\t([^\t]+)$'
  while IFS= read -r row || [[ -n "$row" ]]; do
    [[ -z "$row" || "$row" == \#* ]] && continue
    if [[ ! "$row" =~ $row_pattern ]]; then
      printf '  [blocked] malformed lock row (expected three nonempty TSV fields)\n'
      malformed=1
      continue
    fi
    name=${BASH_REMATCH[1]}
    revision=${BASH_REMATCH[2]}
    digest=${BASH_REMATCH[3]}
    if [[ ! ${expected["$name"]+present} ]]; then
      printf '  [blocked] unexpected lock authority: %s\n' "$name"
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

printf '\nImplementation prerequisites (nonempty files only):\n'
for path in dune-project src/ppx/dune src/driver/dune \
  src/core/ir.ml src/ppx/firewall.ml src/frontend/typed_ast.ml \
  src/why3/translate.ml src/actors/protocol.ml src/abi/manifest.ml \
  src/driver/status.ml; do
  if [[ -f "$ROOT/$path" && -s "$ROOT/$path" ]]; then
    ok "$path present and nonempty"
  else
    missing "$path absent or empty (compiler/verifier integration not implemented)"
  fi
done

printf '\n'
if [[ "$blockers" -eq 0 ]]; then
  printf 'Preflight READY: prerequisites are present. This is NOT verification and grants no proof status.\n'
  exit 0
fi
printf 'Preflight BLOCKED: %d readiness item(s) unresolved. No verification or proof status was produced.\n' "$blockers"
exit 2
