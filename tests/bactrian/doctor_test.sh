#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
doctor="$ROOT/scripts/bactrian/doctor.sh"

help_output=$(bash "$doctor" --help)
grep -q 'cannot establish a proof' <<<"$help_output"

set +e
output=$(bash "$doctor" 2>&1)
status=$?
set -e
if [[ "$status" -ne 2 ]]; then
  printf 'expected blocked preflight exit 2, got %s\n%s\n' "$status" "$output" >&2
  exit 1
fi
grep -q 'Bactrian MVP preflight (not a proof check)' <<<"$output"
grep -q 'Canonical authority lock syntax' <<<"$output"
grep -q 'No verification or proof status was produced' <<<"$output"

set +e
bash "$doctor" --definitely-invalid >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -ne 64 ]]; then
  printf 'expected usage exit 64 for invalid argument, got %s\n' "$status" >&2
  exit 1
fi

# Exercise malformed authority-lock handling without changing the checkout.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/scripts/bactrian" "$tmp/.machine_readable/bactrian"
cp "$doctor" "$tmp/scripts/bactrian/doctor.sh"
cp "$ROOT/.machine_readable/bactrian/authorities.lock" \
  "$tmp/.machine_readable/bactrian/authorities.lock"
printf 'MPR\tUNPINNED\tUNPINNED\n' >>"$tmp/.machine_readable/bactrian/authorities.lock"
set +e
output=$(bash "$tmp/scripts/bactrian/doctor.sh" 2>&1)
status=$?
set -e
if [[ "$status" -ne 2 ]] || ! grep -q 'duplicate authority row: MPR' <<<"$output"; then
  printf 'malformed duplicate authority row was not rejected (exit %s):\n%s\n' \
    "$status" "$output" >&2
  exit 1
fi

printf 'PASS: Bactrian doctor reports blockers honestly and never presents preflight as proof.\n'
