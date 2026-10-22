#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
doctor="$ROOT/scripts/bactrian/doctor.sh"
bash_cmd=$(command -v bash)

help_output=$(bash "$doctor" --help)
grep -q 'cannot establish a proof' <<<"$help_output"

# Control tools, pins, and implementation files independently of checkout readiness.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/scripts/bactrian" "$tmp/.machine_readable/bactrian" "$tmp/bin"
cp "$doctor" "$tmp/scripts/bactrian/doctor.sh"
fixture_doctor="$tmp/scripts/bactrian/doctor.sh"
lock="$tmp/.machine_readable/bactrian/authorities.lock"
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/tool"
chmod +x "$tmp/bin/tool"
for tool in dune ocamlc why3 apalache idris2 zig dkcheck coqc lean echidna; do
  ln -s tool "$tmp/bin/$tool"
done
ln -s "$(command -v dirname)" "$tmp/bin/dirname"

# Synthetic format-valid pins, never used as provenance or proof evidence.
printf -v revision '%040d' 1
printf -v digest '%064d' 2
authorities=(MPR choreographic-types secret-types echo-types epistemic-types occupancy-types tropical-types ECHIDNA)
for name in "${authorities[@]}"; do
  printf '%s\t%s\t%s\n' "$name" "$revision" "$digest"
done >"$lock"
cp "$lock" "$tmp/valid.lock"

run_doctor() {
  local expected_status=$1 status
  shift
  if output=$(PATH="$tmp/bin" BACTRIAN_ECHIDNA_CMD=echidna "$bash_cmd" "$fixture_doctor" "$@" 2>&1); then
    status=0
  else
    status=$?
  fi
  if [[ "$status" -ne "$expected_status" ]]; then
    printf 'expected preflight exit %s, got %s\n%s\n' "$expected_status" "$status" "$output" >&2
    exit 1
  fi
}

run_doctor 2
grep -q 'Bactrian MVP preflight (not a proof check)' <<<"$output"
grep -q 'Canonical authority lock syntax' <<<"$output"
grep -q 'No verification or proof status was produced' <<<"$output"

run_doctor 64 --definitely-invalid

# Dune scaffolding alone must remain blocked even with all tools and pins present.
mkdir -p "$tmp/src/ppx" "$tmp/src/driver"
printf '(lang dune 3.0)\n' >"$tmp/dune-project"
printf '(library (name ppx))\n' >"$tmp/src/ppx/dune"
printf '(library (name driver))\n' >"$tmp/src/driver/dune"
run_doctor 2
grep -q 'src/ppx/firewall.ml absent or empty' <<<"$output"

modules=(src/core/ir.ml src/ppx/firewall.ml src/frontend/typed_ast.ml
  src/why3/translate.ml src/actors/protocol.ml src/abi/manifest.ml src/driver/status.ml)
for path in "${modules[@]}"; do
  mkdir -p "$tmp/$(dirname "$path")"
  printf 'let available = true\n' >"$tmp/$path"
done
run_doctor 0
grep -q 'Preflight READY:.*NOT verification and grants no proof status' <<<"$output"

# Each named module is required; an empty module must also block readiness.
for path in "${modules[@]}"; do
  mv "$tmp/$path" "$tmp/module.ml"
  run_doctor 2
  grep -Fq "$path absent or empty" <<<"$output"
  mv "$tmp/module.ml" "$tmp/$path"
done
: >"$tmp/src/driver/status.ml"
run_doctor 2
grep -q 'src/driver/status.ml absent or empty' <<<"$output"
printf 'let available = true\n' >"$tmp/src/driver/status.ml"

# Malformed MPR rows must fail shape validation before any pin-format checks.
for row in \
  "MPR" \
  $'MPR\t'"$revision" \
  $'\t'"$revision"$'\t'"$digest" \
  $'MPR\t\t'"$digest" \
  $'MPR\t'"$revision"$'\t' \
  $'MPR\t\t'"$revision"$'\t'"$digest" \
  $'MPR\t'"$revision"$'\t\t'"$digest" \
  $'MPR\t'"$revision"$'\t'"$digest"$'\t' \
  $'MPR\t'"$revision"$'\t'"$digest"$'\textra'; do
  grep -v '^MPR' "$tmp/valid.lock" >"$lock"
  printf '%s' "$row" >>"$lock" # Exercise the final row without a newline too.
  run_doctor 2
  grep -q 'malformed lock row (expected three nonempty TSV fields)' <<<"$output"
  if grep -q 'MPR pin fields populated' <<<"$output"; then
    printf 'malformed MPR row reached pin-format checks:\n%s\n' "$output" >&2
    exit 1
  fi
done

cp "$tmp/valid.lock" "$lock"
printf 'MPR\tUNPINNED\tUNPINNED\n' >>"$lock"
run_doctor 2
grep -q 'duplicate authority row: MPR' <<<"$output"

# Comments, blank lines, and a valid final row without a newline are permitted.
printf '# fixture lock\n\n' >"$lock"
grep -v '^MPR' "$tmp/valid.lock" >>"$lock"
printf 'MPR\t%s\t%s' "$revision" "$digest" >>"$lock"
run_doctor 0

printf 'PASS: Bactrian doctor checks controlled blocked/ready fixtures and rejects malformed locks.\n'
