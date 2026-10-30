# Goose msort

`msort.goose` is a Goose v2026.3 implementation of the Rust `msort` command.
It keeps the input in one byte buffer and sorts fixed-size line spans, so field
keys are compared without allocating a string for every comparison. Single
absolute keys and two-key combinations use a decorate-once fast path. At 4,096
rows or more, numeric keys use a stable four-pass LSD radix sort and text keys
use an eight-byte lexicographic prefix radix sort. Prefixes that fully encode
the key need no comparison pass; longer or NUL-containing keys compare only
inside equal-prefix runs. Complex ranges, `NF`, and escape processing fall back
to the general stable comparator.

## Compatibility

The implementation supports the existing command contract:

- `key=N`, `key=N/M`, `key=N@M`, `NF`, and `NF-N`
- string, reverse (`r`), numeric (`n`), and numeric reverse (`nr`, `rn`, `N`)
- stdin or file input, stable sorting, `-e`, `-s<c>`, and existing error text
- `-pN` argument validation and output semantics

`-pN` is currently accepted for CLI compatibility, but Goose sorting is
single-threaded. The benchmark below uses the default single-threaded mode for
both implementations.

Build and run the shared compatibility suite:

```sh
mkdir -p target
goose build -O2 -o target/msort-goose msort.goose
/path/to/rust-commands/cmd/msort/test/run_test.sh target/msort-goose
python3 differential_test.py \
  --reference /path/to/rust-commands/cmd/msort/target/release/msort \
  --candidate target/msort-goose
```

The 2026-10-30 Goose run passed all 162 tests on `origin/main` and 1,012 exact
differential cases against that Rust implementation. Six of those differential
cases contain 8,192 rows and force the radix paths for ascending, descending,
numeric, text, and composite keys. Against the separately tuned Rust branch, it
also passed 1,000 seeded valid-input differential cases. The output of every
benchmark case was compared byte-for-byte through its size and SHA-256 before
timing.

The tuned Rust reference is `origin/adopt/all-commands-uoptim` at commit
`9afe9e84`, built with `cargo build --release --bin msort` and its default
platform-adaptive `optimal` feature. That branch predates the newest strict
error contract: it passes its own 135 tests but passes 146/162 current-main
tests. The 16 differences are outside the measured valid-input cases (error
text/exit timing, CRLF handling, and uppercase `N` compatibility).

## Benchmark

Environment:

- AMD Ryzen 7 2700X, one fixed CPU (`taskset -c 2`)
- Ubuntu, Linux 6.8.0-136, glibc 2.39
- Rust 1.96.0 release build of the tuned wave 1-51 implementation
- Goose v2026.3, `-O2`, GCC 13.3.0
- input generation and output verification excluded from timing
- alternating Rust/Goose order after warm-up

### 500,000 rows (17,444,441 bytes, 2 warm-ups + 11 runs)

| Case | Rust median | Goose before | Goose optimized | Goose speed-up | Rust lead |
|---|---:|---:|---:|---:|---:|
| `key=1` text | 75.954 ms | 399.439 ms | 103.479 ms | 3.860x | 1.362x |
| `key=2n` numeric | 103.654 ms | 227.459 ms | 111.832 ms | 2.034x | 1.079x |
| `key=1@2n` composite | 111.801 ms | 462.930 ms | 133.992 ms | 3.455x | 1.198x |

### 1,000 rows (34,877 bytes, 10 warm-ups + 101 runs)

| Case | Rust median | Goose median | Faster |
|---|---:|---:|---:|
| `key=1` text | 1.576 ms | 1.841 ms | Rust 1.168x |
| `key=2n` numeric | 1.546 ms | 1.781 ms | Rust 1.152x |
| `key=1@2n` composite | 1.711 ms | 1.864 ms | Rust 1.089x |

Raw measurements are in `results/benchmark-before-2026-10-30.json`,
`results/benchmark-optimized-2026-10-30.json`, and
`results/benchmark-small-optimized-2026-10-30.json`. To repeat a run:

```sh
python3 benchmark.py \
  --rust /path/to/tuned-rust-msort \
  --goose target/msort-goose \
  --work-dir /tmp/msort-goose-bench \
  --rows 500000 --warmups 2 --runs 11 --cpu 2
```
