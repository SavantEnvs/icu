#!/usr/bin/env bash
#
# mayhem/build.sh — build ICU4C twice, out of tree under mayhem/build/ (gitignored):
#   fuzz/    sanitized + SanCov + DWARF-3 static ICU, linked into one libFuzzer binary and one
#            -standalone reproducer per upstream harness (icu4c/source/test/fuzzer/*_fuzzer.cpp,
#            the same set OSS-Fuzz's icu build.sh compiles)
#   normal/  upstream's default flags, with cintltst/intltest and the known-answer probe for test.sh
# Everything is built from the checkout, so a re-run is offline.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export CC CXX

ICU="$SRC/icu4c/source"
FUZZ_SRC="$ICU/test/fuzzer"
FUZZ_B="$SRC/mayhem/build/fuzz"
NORM_B="$SRC/mayhem/build/normal"
OBJ="$SRC/mayhem/build/objs"
mkdir -p "$FUZZ_B" "$NORM_B" "$OBJ"

# Defines upstream's OSS-Fuzz build uses (U_USE_STRTOD_L=0: the build fails without it).
DEFINES="-DU_CHARSET_IS_UTF8=1 -DU_USING_ICU_NAMESPACE=0 -DU_ENABLE_DYLOAD=0 -DU_USE_STRTOD_L=0"

# configure_icu <build dir> <cflags> <extra configure args...>: wipes and re-configures only when the flags
# changed (make does not track flags), so a re-run on a built tree keeps its objects.
configure_icu() {
  local dir="$1" flags="$2"; shift 2
  if [ "$(cat "$dir/.mayhem-flags" 2>/dev/null)" != "$flags|$*" ] || [ ! -f "$dir/icudefs.mk" ]; then
    find "$dir" -mindepth 1 -delete
    (cd "$dir" && CFLAGS="$flags" CXXFLAGS="$flags" /bin/bash "$ICU/runConfigureICU" Linux \
        --disable-shared --enable-static --with-data-packaging=static --disable-samples --disable-extras "$@" \
        > configure.log 2>&1) || { tail -30 "$dir/configure.log"; exit 1; }
    printf '%s' "$flags|$*" > "$dir/.mayhem-flags"
  fi
}

# 1) Sanitized + SanCov-instrumented ICU (libraries, plus the tools that compile its data).
#    -fsanitize=fuzzer-no-link goes on the library unconditionally so Mayhem sees coverage in ICU itself.
# ICU's public API takes enum arguments (UCalendarDateFields, UProperty, ...) and range-checks them at run time;
# the harnesses feed raw fuzz bytes in, so UBSan's enum check would abort on valid ICU error handling. Only that
# check is relaxed in the library; everything else in UBSan stays on.
FUZZ_FLAGS="-O1 $SANITIZER_FLAGS -fno-sanitize=enum -fsanitize=fuzzer-no-link $DEBUG_FLAGS $DEFINES"
configure_icu "$FUZZ_B" "$FUZZ_FLAGS" --disable-tests
make -C "$FUZZ_B" -j"$MAYHEM_JOBS" > "$FUZZ_B/make.log" 2>&1 || { tail -40 "$FUZZ_B/make.log"; exit 1; }

# 2) Harnesses: one object each, linked once with the fuzzing engine and once with the run-once driver.
# The harness TUs (only) skip UBSan's alignment and enum checks: several upstream harnesses read their selector bytes
# with reinterpret_cast<const uint16_t*>(data + 1) (misaligned) and load raw bytes into enum types
# (UProperty, UCalendarDateFields, ...), which aborts on nearly every input.
# ICU itself keeps the full UBSan set.
HARNESS_FLAGS="-O1 $SANITIZER_FLAGS -fno-sanitize=alignment,enum -fsanitize=fuzzer-no-link $DEBUG_FLAGS $DEFINES -std=c++17 -I$FUZZ_SRC -I$ICU/common -I$ICU/i18n"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$OBJ/lsan_off.o"
$CXX $HARNESS_FLAGS -c "$FUZZ_SRC/locale_util.cpp" -o "$OBJ/locale_util.o"

harnesses=()
for f in "$FUZZ_SRC"/*_fuzzer.cpp; do harnesses+=("$(basename "$f" .cpp)"); done
[ "${#harnesses[@]}" -ge 33 ] || { echo "expected >=33 harnesses, found ${#harnesses[@]}" >&2; exit 1; }

printf '%s\n' "${harnesses[@]}" | xargs -P "$MAYHEM_JOBS" -I{} \
  $CXX $HARNESS_FLAGS -c "$FUZZ_SRC/{}.cpp" -o "$OBJ/{}.o"

LIBS="-L$FUZZ_B/lib -licutu -licui18n -licuuc -licudata -lpthread -lm"
for h in "${harnesses[@]}"; do
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$OBJ/$h.o" "$OBJ/locale_util.o" "$OBJ/lsan_off.o" \
      $LIB_FUZZING_ENGINE $LIBS -o "$SRC/$h"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$OBJ/$h.o" "$OBJ/locale_util.o" "$OBJ/lsan_off.o" \
      "$OBJ/standalone_main.o" $LIBS -o "$SRC/$h-standalone"
done

# 3) Test build with upstream's NORMAL flags (no sanitizer, no coverage unless asked): ICU's own C and C++
#    suites plus the known-answer probe, left under mayhem/build/normal for test.sh.
configure_icu "$NORM_B" "$DEFINES $COVERAGE_FLAGS" --enable-tests
make -C "$NORM_B" -j"$MAYHEM_JOBS" > "$NORM_B/make.log" 2>&1 || { tail -40 "$NORM_B/make.log"; exit 1; }
make -C "$NORM_B/test/cintltst" -j"$MAYHEM_JOBS" > "$NORM_B/make-cintltst.log" 2>&1 || { tail -40 "$NORM_B/make-cintltst.log"; exit 1; }
make -C "$NORM_B/test/intltest" -j"$MAYHEM_JOBS" > "$NORM_B/make-intltest.log" 2>&1 || { tail -40 "$NORM_B/make-intltest.log"; exit 1; }
make -C "$NORM_B/test/testdata" -j"$MAYHEM_JOBS" > "$NORM_B/make-testdata.log" 2>&1 || { tail -40 "$NORM_B/make-testdata.log"; exit 1; }
$CXX -O2 $DEFINES $COVERAGE_FLAGS -std=c++17 -I"$ICU/common" -I"$ICU/i18n" "$SRC/mayhem/kat/icu_kat.cpp" \
    -L"$NORM_B/lib" -licui18n -licuuc -licudata -lpthread -lm -o "$NORM_B/icu_kat"
