#!/usr/bin/env bash
#
# mayhem/test.sh — RUN ICU's own suites (built by mayhem/build.sh with upstream's normal flags) plus a
# known-answer probe; the probe's stdout is diffed line by line against mayhem/kat/expected.txt.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"
NB="$SRC/mayhem/build/normal"

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

for b in "$NB/icu_kat" "$NB/test/cintltst/cintltst" "$NB/test/intltest/intltest"; do
  [ -x "$b" ] || { echo "missing $b — mayhem/build.sh should have built it" >&2; emit_ctrf icu-kat+cintltst+intltest 0 1; exit 1; }
done

passed=0; failed=0
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# 1) Known-answer probe: every expected line must be produced verbatim.
"$NB/icu_kat" > "$work/kat.out" 2> "$work/kat.err"
while IFS= read -r line; do
  if grep -qxF -- "$line" "$work/kat.out"; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "KAT MISMATCH, expected: $line" >&2; fi
done < "$SRC/mayhem/kat/expected.txt"
[ "$(wc -l < "$work/kat.out")" -eq "$(wc -l < "$SRC/mayhem/kat/expected.txt")" ] || { failed=$((failed + 1)); echo "KAT line count differs" >&2; }

# 2) cintltst (ICU's C API suite): every test leaf prints [OK]; the run must end with the all-passed line.
( cd "$NB/test/cintltst" && ./cintltst > "$work/cintltst.out" 2>&1 )
c_ok=$(grep -c '\[OK\]' "$work/cintltst.out")
if grep -q 'All tests passed successfully' "$work/cintltst.out" && [ "$c_ok" -gt 100 ]; then
  passed=$((passed + c_ok))
else
  failed=$((failed + 1)); tail -40 "$work/cintltst.out" >&2
fi

# 3) intltest (ICU's C++ suite), the deterministic groups (rbbi's monkey tests and the long round-trip groups are left out).
( cd "$NB/test/intltest" && ./intltest utility normalize collate regex format translit rbnf idna convert bidi spoof csdet \
    > "$work/intltest.out" 2>&1 )
if grep -q 'OK: All tests passed without error' "$work/intltest.out"; then
  passed=$((passed + 1))
else
  n=$(sed -n 's/^Errors in total: \([0-9]*\)\..*/\1/p' "$work/intltest.out" | tail -1)
  failed=$((failed + ${n:-1})); tail -40 "$work/intltest.out" >&2
fi

emit_ctrf icu-kat+cintltst+intltest "$passed" "$failed"
