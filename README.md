# roc-deflate

DEFLATE (RFC 1951) compression and decompression in pure Roc.

- `Deflate.compress` produces a raw DEFLATE stream any inflate implementation can read, at a level from 0 to 12.
- `Deflate.decompress` reads all three DEFLATE block types (stored, fixed Huffman, dynamic Huffman), so it handles streams produced by `zlib`, `gzip`, and ZIP tools.
- `Deflate.compress_into` and `Deflate.decompress_into` append to a list you pass in, so one buffer can be emptied and reused across streams instead of allocating a new one for each.
- Decompression is bounded: a hostile stream stops with `OutputLimitExceeded` before its output passes `max_output`, and a declared size, such as a ZIP entry's, reserves the output up front.
- `Deflate.Compressor` and `Deflate.Decoder` keep their tables between streams, so compressing or decompressing many streams allocates them once.

Both are ports of [libdeflate](https://github.com/ebiggers/libdeflate), and the compressor is faithful enough that it produces byte-identical output to libdeflate at every level.

View the API documentation at [https://niclas-ahden.github.io/roc-deflate/](https://niclas-ahden.github.io/roc-deflate/).

## Quick start

```roc
app [main!] {
    pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
    deflate: "https://github.com/niclas-ahden/roc-deflate/releases/download/0.5.1/Cw6pRiwXiLWXafQSc7asFE4wVWQjmaEwXSQW9UAaybpn.tar.zst",
}

import pf.Stdout
import pf.OsStr
import deflate.Deflate

main! = |args| {
    # Compresses the text you pass on the command line, or this line if you
    # pass none
    original = match args.get(0) {
        Ok(arg) => OsStr.display(arg).to_utf8()
        Err(_) => "Bootcut Jeans, salmon shirt, I have a skin routine and my elbows hurt.".to_utf8()
    }

    compressed = Deflate.compress(original, 6)
    Stdout.line!("Compressed ${original.len().to_str()} bytes to ${compressed.len().to_str()}")?

    match Deflate.decompress(compressed, {}) {
        Ok(decompressed) =>
            if decompressed == original {
                Stdout.line!("Round-trip successful")?
            } else {
                Stdout.line!("Round-trip mismatch!")?
            }
        Err(CorruptData) => Stdout.line!("Corrupt DEFLATE stream")?
        Err(UnexpectedEnd) => Stdout.line!("Truncated DEFLATE stream")?
        Err(OutputLimitExceeded) => Stdout.line!("DEFLATE stream larger than its bound")?
    }

    Ok({})
}
```

See [examples](examples/) for a runnable program.

## Bounding decompression

DEFLATE expands up to about 1032:1, so a few kilobytes of hostile input can ask for gigabytes of output. Every decompression takes a `Deflate.Bounds`, whose fields have defaults, and stops with `Err(OutputLimitExceeded)` before writing the byte that would take the output past `max_output`, 1 GiB unless you pass less:

```roc
# A ZIP entry declares its uncompressed size before it is inflated.
Deflate.decompress(entry_bytes, { max_output: declared, expected_size: Declared(declared) })
```

`expected_size: Declared(n)` reserves `n` bytes of output up front, never more than `max_output`, so a truthful size decodes without reallocating. It is a hint, not a check: pass the same `n` as `max_output` to enforce it. Without a declared size, `decompress` starts with room for three times the input.

To decompress many streams, pass one `Deflate.decoder()` through `Deflate.decompress_with`, which hands it back with the output, so its decode tables are allocated once. `Deflate.compressor(level)` and `Deflate.compress_with` do the same for the compressor's matchfinder tables, which are 128 to 512 KiB depending on the level. Either gives exactly the bytes the one-off call does.

## Choosing a level

Levels run from 0 (store the input uncompressed) to 12 (search hardest), and each one selects a parser: level 1 uses a hash-table matchfinder, 2 to 4 are greedy, 5 to 9 are lazy, and 10 to 12 find a minimum-cost path through every match the binary-tree matchfinder can see. Level 6 is the usual default.

A level is a `Deflate.Level`, and a number literal becomes one wherever one is expected, so `Deflate.compress(bytes, 6)` just works and `Deflate.compress(bytes, 13)` is a compile-time error. A level only known at runtime, such as one read from a command-line flag, goes through `Deflate.Level.from_u64`, which returns `Err(OutOfRange)` for anything above 12:

```roc
match Deflate.Level.from_u64(n) {
    Ok(level) => Deflate.compress(bytes, level)
    Err(OutOfRange) => ...
}
```

Because the output is byte-identical to libdeflate's, the compressed size at a given level is exactly libdeflate's compressed size. What differs is how long it takes to get there. Across the twelve files of the [Silesia corpus](http://mattmahoney.net/dc/silesia.html), median throughput over uncompressed bytes:

| Level | Parser       | libdeflate | roc-deflate | libdeflate is |
| ----- | ------------ | ---------- | ----------- | ------------- |
| 1     | hash table   | 278 MB/s   | 65 MB/s     | 304% faster   |
| 6     | lazy         | 101 MB/s   | 20 MB/s     | 401% faster   |
| 9     | lazy2        | 46 MB/s    | 14 MB/s     | 146% faster   |
| 10    | near-optimal | 15 MB/s    | 5.5 MB/s    | 174% faster   |
| 11    | near-optimal | 8.9 MB/s   | 4.1 MB/s    | 136% faster   |
| 12    | near-optimal | 6.7 MB/s   | 3.6 MB/s    | 121% faster   |

The gap narrows as the level rises, since the deeper searches amortize the per-position overhead. There is plenty of room left. See this as a starting point 👍

Reproduce it on your machine with `nix develop -c ./benchmark/compress.roc [level]`, which downloads and verifies the corpus on first run, then runs both engines under mimalloc, compressing into a caller-allocated buffer sized by libdeflate's own bound, and compares the two streams byte for byte. `nix develop -c ./benchmark/decompress.roc` does the same for the decompressor. The dev shell provides the libdeflate source, mimalloc, and the C compiler, so no sibling libdeflate checkout is needed. Set `CORPUS_FILES=xml` (or any space-separated list of Silesia names) for a quicker run.

## Testing

`nix develop -c ./tests.roc` (the flake provides `gzip` and libdeflate's `libdeflate-gzip`) runs:

- the package's `expect` blocks: hand-built streams that pin the decoder to the format (an empty fixed block, a stored block, a bad stored length, a reserved block type, truncations, a match with nothing to copy from), and short round trips at every level,
- gzip interop in both directions on a deterministic 1 MB generated-text corpus: our output at levels 1, 6, 9, and 12 must decode byte-identically under real `gzip`, and real `gzip`'s streams at `-1`/`-6`/`-9` (differing block structures) must inflate byte-identically under our decompressor,
- a round-trip of that same corpus through our own compressor and decompressor at every level from 0 to 12, so no parser goes unexercised,
- byte-identity with libdeflate at every level from 1 to 12, on that corpus and on inputs of zeros, noise, text, and a repeating pattern at every length where some level changes behavior (each passthrough limit, the minimum, soft maximum, and longest block lengths), where every level must also round-trip and stay within `compress_bound`,
- the decoder's error contract: every truncation of a stream reports `UnexpectedEnd`, and flipping any single bit of a stream decodes or fails but never crashes, and
- a compression-ratio gate on the [Canterbury corpus](tests/corpus/): each level's output must stay within a ratchet ceiling, so a change that worsens compression fails the build.

Quite nice!

## Fuzzing

`./fuzz.roc` builds each [roc-fuzz](https://github.com/lukewilliamboswell/roc-fuzz) target in [fuzz/](fuzz/), runs its declared examples, and explores for two seconds; `./fuzz.roc 600` explores for ten minutes each, keeping the corpora under `.fuzz/`. `tests.roc` runs the two-second smoke. The targets check:

- `inflate_bytes`: any bytes, under any bound, decode to `Ok` or a named error, the same answer twice and through a fresh `Decoder`, and the bound agrees exactly with an unbounded decode,
- `compress_round_trip`: structured plaintext at every level round-trips, stays within `compress_bound`, and gives the same bytes through `compress_into`, and a bound cuts the output off exactly at its length,
- `inflate_bomb`: 8 KB that inflate to 8 MiB stop at any bound, under any declared size,
- `state_reuse`: streams through one `Compressor` and one `Decoder` give the bytes the one-off calls do.

Each also wraps the operation in a measured region and asserts allocation ceilings written in the target with the nightly they were measured on: the decoder holds its tables plus its bounded output, never anything in proportion to what a stream asks for, a truthful declared size never reallocates, each level's compressor holds a fixed set of tables plus storage linear in the input, and reused state allocates its tables once. A ceiling only ever moves down.
