#!/bin/zsh
emulate -L zsh
set -euo pipefail

DIR="${0:A:h:h}"
ITERATIONS="${COMMAND_STABILITY_ITERATIONS:-5}"
FILTER='StateFileTransactionTests|DictationTriggerCoordinatorTests|DictationCaptureWatchdogTests|KeyCodesTests|ImportMergeTests'

[[ "$ITERATIONS" == <-> ]] || { print -u2 -- "iterations must be an integer"; exit 2; }
(( ITERATIONS >= 1 && ITERATIONS <= 50 )) || { print -u2 -- "iterations must be between 1 and 50"; exit 2; }

cd "${DIR}/agent"
for iteration in {1..$ITERATIONS}; do
  print -- "[stability] high-risk deterministic pass ${iteration}/${ITERATIONS}"
  if (( iteration == 1 )); then
    swift test --filter "$FILTER"
  else
    swift test --skip-build --filter "$FILTER"
  fi
done

print -- "stability stress: ${ITERATIONS}/${ITERATIONS} deterministic passes"
