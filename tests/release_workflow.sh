#!/usr/bin/env bash
set -eo pipefail

workflow="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/workflows/build.yml"

grep -Fq 'name: Upload SourceForge packages' "$workflow"
if grep -Fq 'steps.sourceforge.outputs.available' "$workflow"; then
  echo 'SourceForge publication must not be skippable' >&2
  exit 1
fi
if grep -Fq 'skipping mirror publication' "$workflow"; then
  echo 'SourceForge publication must not be skipped' >&2
  exit 1
fi

printf 'release workflow checks passed\n'
