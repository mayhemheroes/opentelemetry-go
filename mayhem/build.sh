#!/usr/bin/env bash
#
# opentelemetry-go/mayhem/build.sh — build open-telemetry/opentelemetry-go's OSS-Fuzz targets as
# sanitized libFuzzer binaries, REPLICATING projects/opentelemetry-go/build.sh from google/oss-fuzz:
#
#   cd attribute                       && compile_native_go_fuzzer_v2 $(go list) FuzzHashKVs sdk_attribute_FuzzHashKVs
#   cd sdk/metric/internal/aggregate   && compile_native_go_fuzzer_v2 $(go list) FuzzGetBin  sdk_metric_internal_aggregate_FuzzGetBin
#   cd trace                           && compile_native_go_fuzzer_v2 $(go list) FuzzTraceIDFromHex trace_FuzzTraceIDFromHex
#   cd trace                           && compile_native_go_fuzzer_v2 $(go list) FuzzSpanIDFromHex  trace_FuzzSpanIDFromHex
#
# `compile_native_go_fuzzer_v2` is OSS-Fuzz's go-fuzz-build tooling for NATIVE `func FuzzX(f
# *testing.F)` harnesses (AdamKorcz/go-118-fuzz-build) — there is no legacy `func Fuzz([]byte) int`
# harness in this repo.
#
# MULTI-MODULE (SPEC note): opentelemetry-go is a monorepo of ~25 Go modules. Our 3 fuzz targets live
# in 3 DIFFERENT modules — attribute/ in the root module (go.opentelemetry.io/otel), sdk/metric/
# internal/aggregate/ in go.opentelemetry.io/otel/sdk/metric (sdk/metric/go.mod), and trace/ in
# go.opentelemetry.io/otel/trace (trace/go.mod) — each built from ITS OWN module directory so its
# own go.mod/go.sum (and the repo's `replace go.opentelemetry.io/otel => ../` etc. directives, which
# resolve correctly because we always build from a FULL copy of the repo tree) apply.
#
# We produce:
#   /mayhem/sdk_attribute_FuzzHashKVs
#   /mayhem/sdk_metric_internal_aggregate_FuzzGetBin
#   /mayhem/trace_FuzzTraceIDFromHex
#   /mayhem/trace_FuzzSpanIDFromHex
#
# DWARF gate (SPEC §6.2 item 10): Go's gc compiler always emits DWARF4 (no downgrade flag). The
# C/CGO shim go-118-fuzz-build generates (the cgo LLVMFuzzerTestOneInput wrapper) is compiled by
# clang and defaults to DWARF5 on clang-19. We force that shim to DWARF3 via CGO_CFLAGS/CGO_CXXFLAGS
# and the final clang++ link to DWARF3 via $GO_DEBUG_FLAGS — verify-repo's check reads the FIRST
# .debug_info CU (the C shim, which lands first in the binary), satisfying the < 4 gate.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# OSS-Fuzz's Go path is ASAN-only (project.yaml sanitizers: [address]); UBSan is not part of the Go
# libFuzzer link. Keep ASan as the Go-fuzz sanitizer regardless of the base default. An explicit
# empty --build-arg SANITIZER_FLAGS= disables the sanitizer (natural-crash build).
: "${SANITIZER_FLAGS=-fsanitize=address}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS

# Debug-info flags (SPEC §6.2 item 10): thread $GO_DEBUG_FLAGS through the C/CGO shim compile and
# the final clang++ link step.
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"

# Air-gapped contract (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE. $(go env GOMODCACHE)
# reads the pinned ENV (set in the Dockerfile, under /opt/toolchains — $HOME-independent), so the
# file-proxy path below is correct regardless of which $HOME the re-run executes under. GOSUMDB=off
# (set in the Dockerfile ENV too) avoids a network round-trip to sum.golang.org when `go get` below
# adds a dependency to a go.sum that doesn't already carry its hash.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOSUMDB="${GOSUMDB:-off}"

# Pin the go-118-fuzz-build "testing" shim to the SAME pseudo-version as the go-118-fuzz-build tool
# installed in the Dockerfile (never @latest: the offline re-run must resolve a FIXED, already-cached
# version from $GOMODCACHE instead of re-querying the module proxy for "latest").
GO118FUZZBUILD_TESTING="github.com/AdamKorcz/go-118-fuzz-build/testing@v0.0.0-20250520111509-a70c2aa677fa"

cd "$SRC"
go version

# ── Fresh, throwaway export of the full repo tree for the fuzzer builds ────────────────────────
# attribute/ ships files declaring `package attribute_test` (external test package) ALONGSIDE
# `package attribute` (key_test.go, iterator_test.go, benchmark_test.go, kv_test.go, value_test.go,
# set_test.go). go-118-fuzz-build's package loader errors on two package names in one directory
# ("found packages attribute_test and attribute") — upstream's own OSS-Fuzz build.sh removes those
# files before building. We do the SAME, but ONLY in this throwaway copy (BUILD_ROOT) — never in
# $SRC/attribute — so mayhem/test.sh still runs the FULL upstream suite (incl. those files) against
# the real, untouched source tree. Re-exported from scratch every run — idempotent/re-runnable.
BUILD_ROOT="$SRC/mayhem-build/gofuzz-src"
rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"
git archive HEAD | tar -x -C "$BUILD_ROOT"
grep -rl --include='*.go' '^package .*_test' "$BUILD_ROOT/attribute" 2>/dev/null | xargs -r rm -f

PREP="$SRC/mayhem/go_fuzz_source_prep.py"

# go-118-fuzz-build rewrites the `testing` import of the file holding the target Fuzz function to
# its OWN shim package, which implements testing.T/testing.F but NOT testing.B (and not every stdlib
# *testing.T method, e.g. T.Context). attribute/hash_test.go mixes `func FuzzHashKVs(f *testing.F)`
# with `func Benchmark*(b *testing.B)` in the SAME file, which then fails to compile ("undefined:
# testing.B"). Strip the Benchmark* funcs from THIS throwaway copy only (comment/string-aware brace
# matching) — never from $SRC, so mayhem/test.sh still sees the full, untouched upstream file.
python3 "$PREP" strip-benchmarks "$BUILD_ROOT/attribute/hash_test.go"

# sdk/metric/internal/aggregate/exponential_histogram_test.go is a harder case: besides its OWN
# Benchmark* funcs, go-118-fuzz-build only compiles the ONE file holding the target Fuzz function —
# not the rest of the package's _test.go files — so exponential_histogram_test.go's OTHER Test
# functions (which call unsupported *testing.T methods like Context(), and reference `alice` /
# `dropExemplars` defined in the SIBLING aggregate_test.go) break the build even though FuzzGetBin
# itself never uses them. Replace the file (in BUILD_ROOT only) with JUST what FuzzGetBin + its
# same-file helper `lowerBound` need: those two functions verbatim, plus a minimal reimplementation
# of the `alice` set and `dropExemplars` fixture (trivial: attribute.NewSet of two attributes, and a
# one-line call into the real, non-test DropReservoir — see aggregate_test.go).
AGG_TEST="$BUILD_ROOT/sdk/metric/internal/aggregate/exponential_histogram_test.go"
AGG_BODY="$(python3 "$PREP" extract-funcs-body "$AGG_TEST" FuzzGetBin lowerBound)"
{
  echo 'package aggregate'
  echo
  echo '// Fuzz-only build file (mayhem/build.sh + go_fuzz_source_prep.py): FuzzGetBin + lowerBound'
  echo '// extracted verbatim from exponential_histogram_test.go, plus the small alice/dropExemplars'
  echo '// fixtures FuzzGetBin needs from the SIBLING aggregate_test.go — go-118-fuzz-build only'
  echo '// compiles the ONE file holding the target Fuzz function, not the whole _test.go package.'
  echo
  echo 'import ('
  echo '	"math"'
  echo '	"testing"'
  echo
  echo '	"go.opentelemetry.io/otel/attribute"'
  echo ')'
  echo
  echo 'var ('
  echo '	keyUser   = "user"'
  echo '	userAlice = attribute.String(keyUser, "Alice")'
  echo '	adminTrue = attribute.Bool("admin", true)'
  echo '	alice     = attribute.NewSet(userAlice, adminTrue)'
  echo ')'
  echo
  echo 'func dropExemplars[N int64 | float64](attr attribute.Set) FilteredExemplarReservoir[N] {'
  echo '	return DropReservoir[N](attr)'
  echo '}'
  echo
  printf '%s\n' "$AGG_BODY"
} > "$AGG_TEST"

mkdir -p "$SRC/mayhem-build"

# build_fuzzer <module-dir-under-BUILD_ROOT> <package-import-path> <FuzzFunc> <output-binary-name>
build_fuzzer() {
  local moddir="$1" pkg="$2" func="$3" out="$4"
  (
    cd "$BUILD_ROOT/$moddir"
    go get "$GO118FUZZBUILD_TESTING"
    go-118-fuzz-build -o "$SRC/mayhem-build/$out.a" -func "$func" "$pkg"
  )
  # Link the go-118-fuzz-build c-archive into a libFuzzer binary (ASan) — the go-fuzz-build tooling's
  # own recommended final step (`clang -o fuzzer fuzzer.a -fsanitize=fuzzer`), plus our DWARF3 flags.
  $CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS "$SRC/mayhem-build/$out.a" -o "/mayhem/$out"
  echo "built /mayhem/$out"
}

echo "=== building sdk_attribute_FuzzHashKVs (root module, attribute/) ==="
build_fuzzer "." "go.opentelemetry.io/otel/attribute" FuzzHashKVs sdk_attribute_FuzzHashKVs

echo "=== building sdk_metric_internal_aggregate_FuzzGetBin (sdk/metric module) ==="
build_fuzzer "sdk/metric" "go.opentelemetry.io/otel/sdk/metric/internal/aggregate" FuzzGetBin sdk_metric_internal_aggregate_FuzzGetBin

echo "=== building trace_FuzzTraceIDFromHex (trace module) ==="
build_fuzzer "trace" "go.opentelemetry.io/otel/trace" FuzzTraceIDFromHex trace_FuzzTraceIDFromHex

echo "=== building trace_FuzzSpanIDFromHex (trace module) ==="
build_fuzzer "trace" "go.opentelemetry.io/otel/trace" FuzzSpanIDFromHex trace_FuzzSpanIDFromHex

echo "build.sh complete:"
ls -la /mayhem/sdk_attribute_FuzzHashKVs /mayhem/sdk_metric_internal_aggregate_FuzzGetBin \
       /mayhem/trace_FuzzTraceIDFromHex /mayhem/trace_FuzzSpanIDFromHex
