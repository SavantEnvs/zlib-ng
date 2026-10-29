#!/usr/bin/env bash
#
# mayhem/test.sh — RUN zlib-ng's own ctest/gtest suite plus direct known-answer probes (all built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

TEST_DIR="$SRC/mayhem/build-tests"
for f in "$TEST_DIR/build.ninja" "$TEST_DIR/kat" "$TEST_DIR/minigzip"; do
  [ -e "$f" ] || { echo "missing $f — mayhem/build.sh must build it" >&2; emit_ctrf cmake-ctest+kat 0 1; exit 1; }
done

# Upstream suite. ctest only judges exit codes, so the KAT probes below layer asserted values on top.
ctest_log="$(mktemp)"
ctest --test-dir "$TEST_DIR" -j"$MAYHEM_JOBS" --output-on-failure >"$ctest_log" 2>&1 || true
tail -n 25 "$ctest_log"
summary="$(grep -E 'tests passed, [0-9]+ tests failed out of [0-9]+' "$ctest_log" | tail -n1 || true)"
if [ -z "$summary" ]; then echo "could not parse ctest summary" >&2; emit_ctrf cmake-ctest+kat 0 1; exit 1; fi
failed="$(sed -E 's/.*, ([0-9]+) tests failed out of.*/\1/' <<<"$summary")"
total="$(sed -E 's/.*out of ([0-9]+).*/\1/' <<<"$summary")"
passed=$(( total - failed ))
[ "$total" -ge 60 ] || { echo "ctest ran only $total tests; expected >=60" >&2; failed=$(( failed + 1 )); }

# KAT probes: fixed input -> asserted value, compared here in bash (the neutered program cannot fake it).
kat() {  # kat <name> <expected> <actual>
  if [ "$2" = "$3" ]; then passed=$(( passed + 1 )); else
    failed=$(( failed + 1 )); echo "KAT FAIL $1: expected [$2] got [$3]" >&2; fi
}
expected_kat='adler32(123456789)=091e01de
crc32(123456789)=cbf43926
inflate_len=135
inflate_crc32=001e0058
inflate_adler32=f93c3076
inflate_head=The quick brown fox
roundtrip_levels_0_9=ok'
kat zlib-ng-api "$expected_kat" "$("$TEST_DIR/kat" 2>&1 || true)"

text='zlib-ng known answer: the quick brown fox jumps over the lazy dog'
work="$(mktemp -d)"
printf '%s\n' "$text" | gzip -c > "$work/ref.gz"
kat minigzip-decompress-gzip-output "$text" "$("$TEST_DIR/minigzip" -d -c < "$work/ref.gz" 2>&1 || true)"
printf '%s\n' "$text" | "$TEST_DIR/minigzip" -c > "$work/ours.gz" 2>/dev/null || true
kat gzip-decompress-minigzip-output "$text" "$(gzip -dc "$work/ours.gz" 2>&1 || true)"
rm -rf "$work" "$ctest_log"

emit_ctrf cmake-ctest+kat "$passed" "$failed" 0
