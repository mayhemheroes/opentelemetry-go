#!/usr/bin/env python3
"""go_fuzz_source_prep.py — source-prep helpers for building opentelemetry-go's native
`func FuzzX(f *testing.F)` harnesses with go-118-fuzz-build (AdamKorcz's OSS-Fuzz go-fuzz-build
tooling), used ONLY against the throwaway BUILD_ROOT export in mayhem/build.sh — never against the
real $SRC tree, so mayhem/test.sh still runs the full, untouched upstream suite.

Why this exists: go-118-fuzz-build rewrites the `testing` import of the ONE file holding the target
`func FuzzX` to its own shim package (github.com/AdamKorcz/go-118-fuzz-build/testing), which
implements `testing.T`/`testing.F` but NOT `testing.B`, and not every stdlib `*testing.T` method
(e.g. `T.Context`, added in Go 1.24). It also does not pull in OTHER _test.go files of the same
package, so a Fuzz function that (like this repo's) shares its file with unrelated Test/Benchmark
functions, or depends on a var/func defined in a SIBLING _test.go file, fails to compile stand-alone.

Subcommands:
  strip-benchmarks <file.go> [<file.go> ...]
      Delete every `func Benchmark*(b *testing.B) { ... }` definition IN PLACE (comment/string-aware
      brace matching, so a literal brace inside a string/comment doesn't mis-close the function
      early). Used when the Fuzz function's own file only ADDITIONALLY carries unrelated Benchmarks.

  extract-funcs-body <in-file.go> <func-name> [<func-name> ...]
      Print ONLY the named top-level `func NAME(...) { ... }` definitions (in the order given,
      verbatim, separated by a blank line) to stdout — no package clause, no imports. The caller
      (mayhem/build.sh) wraps this in its own package/import/fixture preamble, because the extracted
      functions may need a var/func defined in a SIBLING _test.go file that go-118-fuzz-build won't
      see (it only compiles the ONE file holding the target Fuzz function).
"""
import re
import sys


def _find_matching_brace(src: str, open_at: int) -> int:
    """Return the index just past the `}` that closes the FIRST `{` found at/after `open_at`
    (comment/string-aware). `open_at` should point at (or before) the function's opening brace."""
    n = len(src)
    k = open_at
    depth = 0
    started = False
    in_str = None  # None | '"' | "'" | '`'
    in_line_comment = False
    in_block_comment = False
    while k < n:
        c = src[k]
        if in_line_comment:
            if c == "\n":
                in_line_comment = False
        elif in_block_comment:
            if src[k : k + 2] == "*/":
                in_block_comment = False
                k += 1
        elif in_str:
            if c == "\\" and in_str != "`":
                k += 1
            elif c == in_str:
                in_str = None
        else:
            if src[k : k + 2] == "//":
                in_line_comment = True
                k += 1
            elif src[k : k + 2] == "/*":
                in_block_comment = True
                k += 1
            elif c in ('"', "'", "`"):
                in_str = c
            elif c == "{":
                depth += 1
                started = True
            elif c == "}":
                depth -= 1
                if started and depth == 0:
                    return k + 1
        k += 1
    raise ValueError("unbalanced braces — no matching close found")


def strip_named_funcs(src: str, name_prefix: str) -> str:
    """Delete every top-level `func <name_prefix>...(` definition."""
    out = []
    i = 0
    n = len(src)
    marker = f"\nfunc {name_prefix}"
    while i < n:
        idx = src.find(marker, i)
        if idx == -1:
            out.append(src[i:])
            break
        out.append(src[i : idx + 1])
        end = _find_matching_brace(src, idx + 1)
        i = end
    return "".join(out)


def extract_func(src: str, func_name: str) -> str:
    m = re.search(rf"\nfunc {re.escape(func_name)}\(", src)
    if not m:
        raise SystemExit(f"function {func_name!r} not found")
    start = m.start() + 1  # drop the leading \n
    end = _find_matching_brace(src, m.end())
    return src[start:end]


def cmd_strip_benchmarks(argv):
    if len(argv) < 1:
        sys.exit("usage: strip-benchmarks <file.go> [<file.go> ...]")
    for path in argv:
        with open(path, encoding="utf-8") as f:
            src = f.read()
        if not re.search(r"^func Benchmark\w*\(", src, re.M):
            continue
        with open(path, "w", encoding="utf-8") as f:
            f.write(strip_named_funcs(src, "Benchmark"))
        sys.stderr.write(f"stripped Benchmark* functions from {path}\n")
    return 0


def cmd_extract_funcs_body(argv):
    if len(argv) < 2:
        sys.exit("usage: extract-funcs-body <in-file.go> <func-name> [<func-name> ...]")
    in_path, *names = argv
    with open(in_path, encoding="utf-8") as f:
        src = f.read()
    parts = [extract_func(src, name).rstrip("\n") for name in names]
    sys.stdout.write("\n\n".join(parts) + "\n")
    return 0


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__ or "")
        return 2
    sub, rest = argv[1], argv[2:]
    if sub == "strip-benchmarks":
        return cmd_strip_benchmarks(rest)
    if sub == "extract-funcs-body":
        return cmd_extract_funcs_body(rest)
    sys.stderr.write(f"unknown subcommand: {sub}\n")
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
