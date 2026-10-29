#!/usr/bin/env bash
#
# mayhem/build.sh — build zlib-ng's 7 in-tree fuzz harnesses (sanitized libFuzzer + standalone reproducers)
# and its upstream test suite (normal flags) for mayhem/test.sh. Runs in the commit image as `mayhem`.
# Re-runnable and air-gapped: gtest comes from the image's libgtest-dev, nothing is fetched.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

FUZZERS="fuzzer_checksum fuzzer_compress fuzzer_example_small fuzzer_example_large fuzzer_example_flush fuzzer_example_dict fuzzer_minigzip"
FUZZ_DIR="$SRC/mayhem/build-fuzz"
SA_DIR="$SRC/mayhem/build-standalone"
TEST_DIR="$SRC/mayhem/build-tests"
mkdir -p "$FUZZ_DIR" "$SA_DIR" "$TEST_DIR"
# Upstream's cmake_dependent_option(WITH_FUZZERS ...) flips to OFF on a reconfigure over an existing cache,
# which breaks re-runs of this script; always configure from a fresh cache (objects are still reused).
rm -f "$FUZZ_DIR/CMakeCache.txt" "$SA_DIR/CMakeCache.txt" "$TEST_DIR/CMakeCache.txt"

# Leak detection off at build time (ASan/UBSan stay on): link this object into every binary.
"$CC" $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.c" -o "$FUZZ_DIR/lsan_off.o"

# 1) libFuzzer binaries. The library is built with the sanitizers + fuzzer-no-link so its code has
#    coverage instrumentation; upstream's CMake picks up $LIB_FUZZING_ENGINE for the fuzzers.
cmake -S "$SRC" -B "$FUZZ_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=None \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link -O2 $DEBUG_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS $FUZZ_DIR/lsan_off.o" \
  -DBUILD_TESTING=ON -DWITH_GTEST=OFF -DWITH_FUZZERS=ON -DWITH_BENCHMARKS=OFF
cmake --build "$FUZZ_DIR" -j"$MAYHEM_JOBS" --target $FUZZERS
for f in $FUZZERS; do
  cp "$(find "$FUZZ_DIR" -type f -name "$f" -perm -u+x | head -n1)" "$SRC/$f"
done

# 2) Standalone reproducers: same harnesses linked with upstream's own run-once driver
#    (test/fuzz/standalone_fuzz_target_runner.c, used when no fuzzing engine is configured).
env -u LIB_FUZZING_ENGINE cmake -S "$SRC" -B "$SA_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=None \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS -O2 $DEBUG_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS $FUZZ_DIR/lsan_off.o" \
  -DBUILD_TESTING=ON -DWITH_GTEST=OFF -DWITH_FUZZERS=ON -DWITH_BENCHMARKS=OFF
env -u LIB_FUZZING_ENGINE cmake --build "$SA_DIR" -j"$MAYHEM_JOBS" --target $FUZZERS
for f in $FUZZERS; do
  cp "$(find "$SA_DIR" -type f -name "$f" -perm -u+x | head -n1)" "$SRC/$f-standalone"
done

# 3) Upstream test suite (ctest + gtest) with the project's NORMAL flags, plus the KAT probe.
cmake -S "$SRC" -B "$TEST_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS" \
  -DBUILD_TESTING=ON -DWITH_GTEST=ON -DWITH_FUZZERS=OFF -DWITH_BENCHMARKS=OFF
cmake --build "$TEST_DIR" -j"$MAYHEM_JOBS"
"$CC" -O2 $COVERAGE_FLAGS "$SRC/mayhem/kat.c" -I"$TEST_DIR" -I"$SRC" \
  "$TEST_DIR/libz-ng.a" -o "$TEST_DIR/kat"
