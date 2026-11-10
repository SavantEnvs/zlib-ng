#!/usr/bin/env bash
#
# mayhem/build.sh — build the gzbuffer fuzz harness (sanitized libFuzzer + standalone reproducer; mining branch)
# and zlib-ng's upstream test suite (normal flags) for mayhem/test.sh. Runs in the commit image as `mayhem`.
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

FUZZERS="fuzzer_gzbuffer"
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
  -DBUILD_TESTING=ON -DWITH_GTEST=OFF -DWITH_FUZZERS=OFF -DWITH_BENCHMARKS=OFF
cmake --build "$FUZZ_DIR" -j"$MAYHEM_JOBS" --target zlib-ng-static
LIB="$(find "$FUZZ_DIR" -type f -name libz-ng.a | head -n1)"
"$CC" $SANITIZER_FLAGS -fsanitize=fuzzer-no-link -O2 $DEBUG_FLAGS -I"$FUZZ_DIR" -I"$SRC" -DWITH_GZFILEOP -c "$SRC/mayhem/fuzzer_gzbuffer.c" -o "$FUZZ_DIR/fuzzer_gzbuffer.o"
"$CC" $SANITIZER_FLAGS $LIB_FUZZING_ENGINE "$FUZZ_DIR/fuzzer_gzbuffer.o" "$LIB" "$FUZZ_DIR/lsan_off.o" -o "$SRC/fuzzer_gzbuffer"

# 2) Standalone reproducer: the same harness linked with the base's run-once driver, no libFuzzer runtime.
env -u LIB_FUZZING_ENGINE cmake -S "$SRC" -B "$SA_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=None \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS -O2 $DEBUG_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS $FUZZ_DIR/lsan_off.o" \
  -DBUILD_TESTING=ON -DWITH_GTEST=OFF -DWITH_FUZZERS=OFF -DWITH_BENCHMARKS=OFF
env -u LIB_FUZZING_ENGINE cmake --build "$SA_DIR" -j"$MAYHEM_JOBS" --target zlib-ng-static
SA_LIB="$(find "$SA_DIR" -type f -name libz-ng.a | head -n1)"
"$CC" $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$SA_DIR/standalone_main.o"
"$CC" $SANITIZER_FLAGS -O2 $DEBUG_FLAGS -I"$SA_DIR" -I"$SRC" -DWITH_GZFILEOP -c "$SRC/mayhem/fuzzer_gzbuffer.c" -o "$SA_DIR/fuzzer_gzbuffer.o"
"$CC" $SANITIZER_FLAGS "$SA_DIR/fuzzer_gzbuffer.o" "$SA_DIR/standalone_main.o" "$SA_LIB" "$FUZZ_DIR/lsan_off.o" -o "$SRC/fuzzer_gzbuffer-standalone"

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
