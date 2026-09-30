# roc-deflate

DEFLATE (RFC 1951) compression and decompression in pure Roc.

- `Deflate.compress` produces a raw DEFLATE stream any inflate implementation can read, at a level from 0 to 12.
- `Deflate.decompress` reads all three DEFLATE block types (stored, fixed Huffman, dynamic Huffman), so it handles streams produced by `zlib`, `gzip`, and ZIP tools.

Both are ports of [libdeflate](https://github.com/ebiggers/libdeflate), and the compressor is faithful enough that it produces byte-identical output to libdeflate at every level.

View the API documentation at [https://niclas-ahden.github.io/roc-deflate/](https://niclas-ahden.github.io/roc-deflate/).

## Quick start

```roc
app [main!] {
    pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0/GNN5tt2gKdX4dhawg4915C4YB193woHFdcCkz31fhGxv.tar.zst",
    deflate: "https://github.com/niclas-ahden/roc-deflate/releases/download/0.3.0/9d7QRzf6vgYMDqXgTsL5sTh8B475yeL8KUAp8TJKs2Q5.tar.zst",
}

import pf.Stdout
import pf.OsStr
import deflate.Deflate

main! = |args| {
    # Compresses the text you pass on the command line, or this line if you
    # pass none
    original = match args.get(1) {
        Ok(arg) => OsStr.display(arg).to_utf8()
        Err(_) => "Bootcut Jeans, salmon shirt, I have a skin routine and my elbows hurt.".to_utf8()
    }

    compressed = Deflate.compress(original, 6) ? |_| Exit(1)
    Stdout.line!("Compressed ${original.len().to_str()} bytes to ${compressed.len().to_str()}")?

    match Deflate.decompress(compressed) {
        Ok(decompressed) =>
            if decompressed == original {
                Stdout.line!("Round-trip successful")?
            } else {
                Stdout.line!("Round-trip mismatch!")?
            }
        Err(CorruptData) => Stdout.line!("Corrupt DEFLATE stream")?
        Err(UnexpectedEnd) => Stdout.line!("Truncated DEFLATE stream")?
    }

    Ok({})
}
```

See [examples](examples/) for a runnable program.

## Choosing a level

Levels run from 0 (store the input uncompressed) to 12 (search hardest), and each one selects a parser: level 1 uses a hash-table matchfinder, 2 to 4 are greedy, 5 to 9 are lazy, and 10 to 12 find a minimum-cost path through every match the binary-tree matchfinder can see. Level 6 is the usual default.

Because the output is byte-identical to libdeflate's, the compressed size at a given level is exactly libdeflate's compressed size; what differs is how long it takes to get there. Across the twelve files of the [Silesia corpus](http://mattmahoney.net/dc/silesia.html), median throughput over uncompressed bytes:

| Level | Parser       | libdeflate | roc-deflate | libdeflate is |
| ----- | ------------ | ---------- | ----------- | ------------- |
| 1     | hash table   | 278 MB/s   | 65 MB/s     | 304% faster   |
| 6     | lazy         | 101 MB/s   | 20 MB/s     | 401% faster   |
| 9     | lazy2        | 46 MB/s    | 14 MB/s     | 146% faster   |
| 10    | near-optimal | 15 MB/s    | 5.5 MB/s    | 174% faster   |
| 11    | near-optimal | 8.9 MB/s   | 4.1 MB/s    | 136% faster   |
| 12    | near-optimal | 6.7 MB/s   | 3.6 MB/s    | 121% faster   |

The gap narrows as the level rises, since the deeper searches amortize the per-position overhead. There is plenty of room left. See this as a starting point 👍

Reproduce it on your machine with `./benchmark/compress.sh [level]`, which downloads and verifies the corpus on first run, then runs both engines under mimalloc, compressing into a caller-allocated buffer sized by libdeflate's own bound, and compares the two streams byte for byte. `./benchmark/decompress.sh` does the same for the decompressor.

## Testing

`./tests.roc` (or `nix develop -c ./tests.roc` to get `gzip` and coreutils from the flake instead of the host) runs:

- gzip interop in both directions on a deterministic 1 MB generated-text corpus: our output at levels 1, 6, 9, and 12 must decode byte-identically under real `gzip`, and real `gzip`'s streams at `-1`/`-6`/`-9` (differing block structures) must inflate byte-identically under our decompressor,
- a round-trip of that same corpus through our own compressor and decompressor at every level from 0 to 12, so no parser goes unexercised, and
- a compression-ratio gate on the [Canterbury corpus](tests/corpus/): each level's output must stay within a ratchet ceiling, so a change that worsens compression fails the build.

Quite nice!
