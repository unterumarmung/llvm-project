#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./run-wide-redundant-nested-if-validation.sh [jobs] [--stages stages]
       ./run-wide-redundant-nested-if-validation.sh [--jobs jobs] [--stages stages]

Stages:
  build-before-tidy   cmake --build build-wide-tidy -j<jobs>
  tidy-fix            run readability-redundant-nested-if with -fix and profiling
  build-after-tidy    cmake --build build-wide-tidy -j<jobs>
  check-all           cmake --build build-wide-tidy --target check-all -j<jobs>

Stage aliases:
  build1, tidy, build2, check

Examples:
  ./run-wide-redundant-nested-if-validation.sh 14
  ./run-wide-redundant-nested-if-validation.sh --jobs 14 --stages tidy,build2
  ./run-wide-redundant-nested-if-validation.sh --stages check-all

If jobs is omitted, the script uses getconf _NPROCESSORS_ONLN.
If stages is omitted, all stages run in order.
USAGE
}

JOBS=""
STAGES="build-before-tidy,tidy-fix,build-after-tidy,check-all"

while [[ $# -gt 0 ]]; do
  case "$1" in
  -h|--help)
    usage
    exit 0
    ;;
  -j|--jobs)
    if [[ $# -lt 2 ]]; then
      echo "error: $1 requires a value" >&2
      exit 2
    fi
    JOBS="$2"
    shift 2
    ;;
  --stages)
    if [[ $# -lt 2 ]]; then
      echo "error: --stages requires a value" >&2
      exit 2
    fi
    STAGES="$2"
    shift 2
    ;;
  --stages=*)
    STAGES="${1#--stages=}"
    shift
    ;;
  --jobs=*)
    JOBS="${1#--jobs=}"
    shift
    ;;
  [1-9][0-9]*)
    if [[ -n "$JOBS" ]]; then
      echo "error: jobs specified more than once" >&2
      exit 2
    fi
    JOBS="$1"
    shift
    ;;
  *)
    echo "error: unknown argument: $1" >&2
    usage >&2
    exit 2
    ;;
  esac
done

JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN)}
if ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: jobs must be a positive integer" >&2
  usage >&2
  exit 2
fi

ROOT=/tmp/llvm-wide-tidy-validation
BUILD="$ROOT/build-wide-tidy"
LOGDIR=/private/tmp/llvm-wide-tidy-validation-logs-$(date +%Y%m%d-%H%M%S)
mkdir -p "$LOGDIR"

normalize_stage() {
  case "$1" in
  build-before-tidy|build1)
    echo build-before-tidy
    ;;
  tidy-fix|tidy)
    echo tidy-fix
    ;;
  build-after-tidy|build2)
    echo build-after-tidy
    ;;
  check-all|check)
    echo check-all
    ;;
  *)
    echo "error: unknown stage: $1" >&2
    usage >&2
    exit 2
    ;;
  esac
}

IFS=',' read -r -a REQUESTED_STAGES <<< "$STAGES"
NORMALIZED_STAGES=()
for Stage in "${REQUESTED_STAGES[@]}"; do
  Stage="${Stage//[[:space:]]/}"
  if [[ -z "$Stage" ]]; then
    continue
  fi
  NORMALIZED_STAGES+=("$(normalize_stage "$Stage")")
done

if [[ ${#NORMALIZED_STAGES[@]} -eq 0 ]]; then
  echo "error: no stages selected" >&2
  exit 2
fi

run_step() {
  local name="$1"
  shift
  local logfile="$LOGDIR/${name}.log"
  local start end status
  echo "== $name ==" | tee -a "$LOGDIR/summary.log"
  echo "command: $*" | tee -a "$LOGDIR/summary.log"
  start=$(date +%s)
  set +e
  /usr/bin/time -p "$@" 2>&1 | tee "$logfile"
  status=${PIPESTATUS[0]}
  set -e
  end=$(date +%s)
  printf '%s: exit=%d elapsed=%ss log=%s\n' "$name" "$status" "$((end - start))" "$logfile" | tee -a "$LOGDIR/summary.log"
  if [[ $status -ne 0 ]]; then
    echo "failed step: $name" | tee -a "$LOGDIR/summary.log"
    exit "$status"
  fi
}

run_selected_stage() {
  case "$1" in
  build-before-tidy)
    run_step 01-build-before-tidy cmake --build "$BUILD" -j"$JOBS"
    ;;
  tidy-fix)
    run_step 02-run-clang-tidy-fix \
      clang-tools-extra/clang-tidy/tool/run-clang-tidy.py \
      -p "$BUILD" \
      -clang-tidy-binary "$BUILD/bin/clang-tidy" \
      -clang-apply-replacements-binary "$BUILD/bin/clang-apply-replacements" \
      -checks=-*,readability-redundant-nested-if \
      -fix \
      -enable-check-profile \
      -j"$JOBS" \
      '^/tmp/llvm-wide-tidy-validation/(llvm|clang|mlir|flang|libcxx)/'
    {
      echo "git status after tidy:"
      git status --short
      echo "git diff stat after tidy:"
      git diff --stat
    } | tee "$LOGDIR/02-post-tidy-diff-summary.log" | tee -a "$LOGDIR/summary.log"
    ;;
  build-after-tidy)
    run_step 03-build-after-tidy cmake --build "$BUILD" -j"$JOBS"
    ;;
  check-all)
    run_step 04-check-all cmake --build "$BUILD" --target check-all -j"$JOBS"
    ;;
  esac
}

cd "$ROOT"

echo "logs: $LOGDIR" | tee "$LOGDIR/summary.log"
echo "jobs: $JOBS" | tee -a "$LOGDIR/summary.log"
echo "stages: ${NORMALIZED_STAGES[*]}" | tee -a "$LOGDIR/summary.log"
echo "start: $(date)" | tee -a "$LOGDIR/summary.log"
echo "initial git status:" | tee -a "$LOGDIR/summary.log"
git status --short | tee -a "$LOGDIR/summary.log"

for Stage in "${NORMALIZED_STAGES[@]}"; do
  run_selected_stage "$Stage"
done

echo "finish: $(date)" | tee -a "$LOGDIR/summary.log"
echo "logs: $LOGDIR" | tee -a "$LOGDIR/summary.log"
