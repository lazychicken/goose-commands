# goose-commands

Goose implementations of commands from `lazychicken/rust-commands`, with
byte-for-byte compatibility tests and reproducible Rust-vs-Goose benchmarks.

| Command | Status | Compatibility | Large-input result |
|---|---|---|---|
| [`msort`](commands/msort/) | implemented | 162/162 fixed tests and 1,012/1,012 differential cases | 2.03x-3.86x faster than the initial Goose version |

The repository stores source, test drivers, and raw benchmark reports. Compiler
outputs, generated inputs, and benchmark scratch files are intentionally not
tracked.

## Build `msort`

```sh
goose build -O2 -o msort-goose commands/msort/msort.goose
```

See [`commands/msort/README.md`](commands/msort/README.md) for compatibility,
benchmark methodology, and repeat commands.
