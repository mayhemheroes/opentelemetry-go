# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile — GO target (open-telemetry/opentelemetry-go, a multi-module monorepo:
# go.opentelemetry.io/otel at the repo root, go.opentelemetry.io/otel/sdk/metric under sdk/metric/,
# go.opentelemetry.io/otel/trace under trace/, ...). Builds ON TOP of the org C/C++ base image
# (ghcr.io/mayhemheroes/base) — clang is needed to link the go-fuzz-build libFuzzer archive — adding
# a pinned Go toolchain + the AdamKorcz/go-118-fuzz-build tool (OSS-Fuzz's `compile_native_go_fuzzer_v2`
# path, for NATIVE `func FuzzX(f *testing.F)` harnesses; this repo has no legacy `func Fuzz([]byte) int`
# harness, so the legacy go114-fuzz-build/go-fuzz tool is not installed).
#
# WHY a Go-specific template (SPEC §6.2 items 8/9, §6.5): Go's GOPATH/GOMODCACHE default to $HOME/go.
# The commit build and the PATCH RL re-run use DIFFERENT $HOMEs, so a cache left at the default would
# vanish under the re-run identity. We pin GOROOT/GOPATH/GOMODCACHE/GOCACHE at FIXED, $HOME-independent
# paths under /opt/toolchains so the module cache the FIRST (online) build fills is found again — by
# the SAME absolute GOMODCACHE — when build.sh re-runs OFFLINE at the PATCH tier.
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t opentelemetry-go-commit:test .

FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); never bake it as ENV — an empty value
# breaks clang. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default.
# NOTE: OSS-Fuzz's Go path is ASAN-only (project.yaml sanitizers: [address]) — the Go fuzz binary is
# built with ASan and links the libFuzzer engine; build.sh pins ASan regardless of the base default.
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# Pin the Go toolchain by version AND tarball sha256 (reproducible fetch). go.mod across the modules
# declares `go 1.25.0` (minimum); pin a current stable that satisfies it.
ARG GO_VERSION=1.26.4
ARG GO_SHA256=1153d3d50e0ac764b447adfe05c2bcf08e889d42a02e0fe0259bd47f6733ad7f
# Pin go-118-fuzz-build (the go-fuzz-build tooling for native testing.F harnesses) by PSEUDO-VERSION,
# never @latest — the offline PATCH re-run must resolve the exact same, already-cached version.
ARG GO118FUZZBUILD_VERSION=v0.0.0-20250520111509-a70c2aa677fa

# ── Go toolchain @ a FIXED, lockable, $HOME-independent prefix ──────────────────────────────────
# SPEC §6.2 item 8 + §6.5: commit build and PATCH re-run run under different $HOMEs. Pinning
# GOROOT/GOPATH/GOMODCACHE/GOCACHE under /opt/toolchains ensures the module cache populated during
# the first (online) image build is found again when build.sh re-runs OFFLINE at the PATCH tier.
ENV GOROOT=/opt/toolchains/go \
    GOPATH=/opt/toolchains/go-path \
    GOMODCACHE=/opt/toolchains/go-path/pkg/mod \
    GOCACHE=/opt/toolchains/go-path/build-cache \
    GOTOOLCHAIN=local \
    GOFLAGS=-mod=mod \
    GOSUMDB=off \
    PATH=/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:/usr/local/bin:/usr/bin:/bin

# ── Install Go + the go-118-fuzz-build tool (root step) ────────────────────────────────────────
# The base image is C/C++-only; add the official Go tarball at a fixed prefix, then install
# go-118-fuzz-build — the tool that compiles a native `func FuzzX(f *testing.F)` harness into a
# libFuzzer-linkable c-archive (this ALSO seeds its own module + the go-118-fuzz-build/testing shim
# it depends on into GOMODCACHE, which build.sh's `go get` needs again, offline, at the PATCH tier).
USER root
RUN install -d /opt/toolchains/go-path \
    && wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go.tgz \
    && echo "${GO_SHA256}  /tmp/go.tgz" | sha256sum -c - \
    && tar -C /opt/toolchains -xzf /tmp/go.tgz && rm -f /tmp/go.tgz \
    && go version \
    && go install "github.com/AdamKorcz/go-118-fuzz-build@${GO118FUZZBUILD_VERSION}" \
    && ls -la "$(go env GOPATH)/bin" \
    && chmod -R a+rX /opt/toolchains/go \
    && chown -R 2000:2000 /opt/toolchains/go-path \
    && go clean -cache 2>/dev/null || true

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git history) is
# copied to /mayhem as `mayhem`; build.sh builds in place.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run opentelemetry-go's own Go test suites at build time (a failing suite fails the image build).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
