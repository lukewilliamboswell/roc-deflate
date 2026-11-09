# Echo + clock

A small C platform for native macOS benchmarks. The entire application-facing
API is:

```roc
import pf.Host exposing [echo!, now!]
# echo! : Str => {}
# now!  : () => U64
```

`echo!` writes a string and a newline. `now!` reads `CLOCK_MONOTONIC` in
nanoseconds from an unspecified origin; subtract two readings for elapsed time.
The app supplies `main! : U64 => {}`. Its one entry argument is an optional unsigned
integer on the command line (default 0). This lets the runner select a case at
runtime without adding a hosted effect or precomputing compression. Inputs are
imported at compile time as `List(U8)`; no file or network effects are provided.

Roc allocations call **mimalloc directly**, statically linked at v2.1.7 commit
`8c532c32c3c96e5ba1f2283e032f69ead8add00f`, the same version as the existing
C/Roc measurements. No `DYLD_INSERT_LIBRARIES` or other allocator override is
needed. This covers Roc allocations; libc may allocate its own stdout buffers.

From the repository root:

```sh
benchmark/echo-clock/build.sh
roc build --no-cache --opt=speed benchmark/echo-clock/example.roc --output=/tmp/echo-clock-example
/tmp/echo-clock-example
```

The build needs a C compiler, curl, tar, and shasum. It downloads the pinned
mimalloc archive, verifies its SHA-256, and compiles two objects. Later builds
reuse the downloaded archive. The platform currently ships target declarations
and a native build script for Apple Silicon and Intel macOS. The C clock uses
POSIX; Linux link inputs and WebAssembly host clock imports are not supplied.

The example imports the repository README as bytes, compresses it, verifies a
round trip, and prints the elapsed time. Its level depends on the runtime entry
argument to prevent compile-time compression.

## Embedded-input measurements

`measure.py` builds a C and a Roc executable for each Silesia file. Both embed
the original input bytes and call mimalloc directly. Roc imports the inputs
and the expected compressed streams; it needs no runtime file API. The C
driver uses the pinned libdeflate checkout supplied on the command line.

```sh
python3 benchmark/echo-clock/measure.py build \
  --roc /absolute/path/to/roc \
  --corpus /absolute/path/to/silesia-files \
  --libdeflate /absolute/path/to/libdeflate \
  --out /absolute/path/to/results
python3 benchmark/echo-clock/measure.py run \
  --roc /absolute/path/to/roc \
  --corpus /absolute/path/to/silesia-files \
  --libdeflate /absolute/path/to/libdeflate \
  --out /absolute/path/to/results
```

Defaults are all 12 files, levels 1–12, three rounds, and five repetitions per
case per round. `--files`, `--levels`, `--rounds`, and `--reps` can select a
smaller experiment. The files, levels, and repetitions are fixed when building;
`run` reads them from `build.json`. `--rounds` controls the measurement run.
Builds use a fixed staging path and disable the Roc compilation cache. Run
builds serially, and finish builds and other CPU-intensive work before timing.

Each engine warms the same reusable output buffer for at least 200 ms, including
the initial compression and decompression check, before timing. Every measured
compression is checked outside the timed interval: Roc must reproduce
libdeflate's exact bytes, and C must reproduce its warmup output. Both reuse an
output buffer. C also reuses its compressor object; Roc uses `compress_into`,
which creates its internal scratch storage per call. Those are the respective
library APIs, and internal Roc allocations remain inside the timed region.

Both engines run one file/level case per process. The runner passes the selected
level number to Roc as the runtime entry argument, which also prevents compile-time
compression. This keeps allocator history from other compression levels out of
the comparison. The runner alternates which engine runs first across rounds.
It records every observation in `timings.csv`, preserves process output in
`raw/`, and writes source, compiler, executable, corpus, and reference hashes
in `build.json`. `run.json` identifies the build, round count, start/end times,
and sample count. The runner rejects missing, duplicate, or unexpected samples
and changed inputs or executables.

`summary.csv` compares each case's median elapsed time. Its gap is
`100 * (Roc median / C median - 1)`; positive means Roc takes longer. These
embedded-input measurements form a new benchmark series. Earlier CSVs from
the basic-cli harness retain their original provenance and should be identified
separately when comparing results.

Run the focused checks with:

```sh
ROC=/path/to/roc benchmark/echo-clock/test.sh
```

They exercise allocation alignment and resizing, small/static/shared/sliced
string ownership (including embedded NUL output), monotonic readings, and the
compression example and 64-bit entry arguments under both native dev and LLVM
speed compilation. Verified on Apple M1 Pro with Roc
`5e62c0e13ae779c28f7904dcdd2849ba13240beb` and
`d99c7b838fb05bb1047eb0c18d4d06d0f86f345d`.

`roc_platform_abi.h` is generated by Roc's C glue specification. To
regenerate it after changing the interface:

```sh
roc glue --no-cache /path/to/roc/src/glue/src/CGlue.roc \
    benchmark/echo-clock benchmark/echo-clock/main.roc
```

When distributing compiled platform objects, include the copied
`targets/<target>/mimalloc-LICENSE.txt` alongside them.
