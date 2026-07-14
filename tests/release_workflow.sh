#!/usr/bin/env bash
set -eo pipefail

workflow="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/workflows/build.yml"
gate="if: \${{ steps.sourceforge.outputs.available == 'true' }}"

grep -Fq 'id: sourceforge' "$workflow"
grep -Fq 'ls /home/frs/project/forkop' "$workflow"
[ "$(grep -Fc "$gate" "$workflow")" -eq 4 ]
grep -Fq 'SourceForge project is unavailable; skipping mirror publication' "$workflow"

printf 'release workflow checks passed\n'
