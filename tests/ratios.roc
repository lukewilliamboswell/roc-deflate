## Compression-ratio regression gate on the committed Canterbury corpus.
##
## Reads tests/corpus/canterbury.bin, compresses it at each level, and fails if
## any level's output exceeds its committed ceiling. The ceilings are a
## ratchet: each equals the current output size, so only a genuine ratio
## regression trips the gate. When compression improves, tighten the number
## here to lock the win in.
##
## The corpus is read from disk, so `Deflate.compress` operates on runtime
## bytes and is never evaluated at compile time.
##
##     roc build --opt=speed tests/ratios.roc && ./tests/ratios
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0/GNN5tt2gKdX4dhawg4915C4YB193woHFdcCkz31fhGxv.tar.zst",
	deflate: "../package/main.roc",
}

import pf.Stdout
import pf.Path
import pf.IOErr exposing [IOErr]
import pf.OsStr
import deflate.Deflate

# Ratchet ceilings: the current Deflate output size in bytes for the Canterbury
# corpus at each level. Lower these when compression improves.
max_level_1 = 791919
max_level_6 = 721981
max_level_9 = 694996
max_level_12 = 673464

main! = |_| {
	path = OsStr.from_str("tests/corpus/canterbury.bin")
	corpus = Path.read_bytes!(Path.from_os_str(path)) ? |_| Exit(1)
	Stdout.line!("corpus: ${corpus.len().to_str()} bytes (Canterbury)")?

	check!("level 1", corpus, 1, max_level_1)?
	check!("level 6", corpus, 6, max_level_6)?
	check!("level 9", corpus, 9, max_level_9)?
	check!("level 12", corpus, 12, max_level_12)?

	Stdout.line!("All ratio gates passed")?
	Ok({})
}

# Compress at one level and fail if the output is larger than the ceiling.
check! : Str, List(U8), U64, U64 => Try({}, [Exit(I32), StdoutErr(IOErr), ..])
check! = |name, corpus, level, ceiling| {
	size = (Deflate.compress(corpus, level) ? |_| Exit(1)).len()
	if size <= ceiling {
		Stdout.line!("  ${name}: ${size.to_str()} bytes (ceiling ${ceiling.to_str()})")
	} else {
		Stdout.line!("  ${name}: REGRESSION — ${size.to_str()} > ceiling ${ceiling.to_str()}")?
		Err(Exit(1))
	}
}
