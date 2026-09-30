## Interop tests against real gzip, both directions, in-process.
##
## A deterministic corpus is generated in memory and written to a temp file.
## Forward: our DEFLATE stream is wrapped in a gzip container and handed to
## real `gzip -d`, whose output must equal the corpus. Reverse: real `gzip`
## compresses the corpus, and our decompressor must reproduce it from the raw
## DEFLATE stream (gzip's 10-byte header and 8-byte trailer removed). Passing
## both directions proves standard compliance against an independent codec.
##
## gzip only ever reads a file and writes to stdout (which we capture), so no
## large payload is fed to its stdin and there is no pipe-buffer deadlock.
##
##     roc tests/harness.roc
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0/GNN5tt2gKdX4dhawg4915C4YB193woHFdcCkz31fhGxv.tar.zst",
	deflate: "../package/main.roc",
	crc32: "https://github.com/niclas-ahden/roc-crc32/releases/download/1.0.3/H7PGfAdWAHVHcw2RHGRkXzEZzzNjhmYm8vcDMmYvogw7.tar.zst",
}

import pf.Stdout
import pf.Cmd
import pf.Path
import pf.Env
import pf.IOErr exposing [IOErr]
import pf.OsStr exposing [OsStr]
import deflate.Deflate
import crc32.Crc32
import TextGen

main! = |args| {
	# `+ args.len()` keeps the corpus size runtime-dependent. With a literal
	# length, TextGen.generate and the Deflate.compress calls below become fully
	# compile-time-known, and the compiler evaluates the whole compression at
	# build time — which balloons to ~45 GB and OOM-kills the build. args.len()
	# is 1 with no arguments, so the corpus stays deterministic across runs.
	corpus = TextGen.generate(42, 1000000 + args.len())
	tmp = Env.temp_dir!()
	corpus_path = tmp.join("roc_deflate_harness_corpus.bin")
	corpus_os = OsStr.from_raw(Path.to_raw(corpus_path))
	Path.write_bytes!(corpus_path, corpus) ? |_| Exit(1)

	Stdout.line!("corpus: ${corpus.len().to_str()} bytes")?

	Stdout.line!("== forward: real gzip decodes our streams")?
	check_forward!(corpus, tmp, "level 1", 1)?
	check_forward!(corpus, tmp, "level 6", 6)?
	check_forward!(corpus, tmp, "level 9", 9)?
	check_forward!(corpus, tmp, "level 12", 12)?

	Stdout.line!("== reverse: we inflate real gzip's streams")?
	check_reverse!(corpus, corpus_os, "-1")?
	check_reverse!(corpus, corpus_os, "-6")?
	check_reverse!(corpus, corpus_os, "-9")?

	# Every level, including the ones gzip interop above does not cover. Each
	# level selects a different parser or a different search effort, so a level
	# that is never exercised is a parser that is never exercised.
	Stdout.line!("== round-trip through our own decompressor, every level")?
	var $level = 0.U64
	while $level <= 12 {
		check_roundtrip!(corpus, $level)?
		$level = $level + 1
	}

	Path.delete!(corpus_path) ? |_| Exit(1)
	Stdout.line!("All interop checks passed")?
	Ok({})
}

# Compress and then decompress with our own code, and confirm the bytes come
# back unchanged.
check_roundtrip! : List(U8), U64 => Try({}, [Exit(I32), StdoutErr(IOErr)])
check_roundtrip! = |corpus, level| {
	deflated = Deflate.compress(corpus, level) ? |_| Exit(1)
	back = Deflate.decompress(deflated) ? |_| Exit(1)
	if back == corpus {
		Stdout.line!("  level ${level.to_str()}: round-tripped ${deflated.len().to_str()} bytes")
	} else {
		Stdout.line!("  level ${level.to_str()}: MISMATCH")?
		Err(Exit(1))
	}
}

# Compress with our encoder, wrap in a gzip member, and confirm real gzip
# decodes it back to the exact corpus.
check_forward! : List(U8), Path.Path, Str, U64 => Try({}, [Exit(I32), StdoutErr(IOErr)])
check_forward! = |corpus, tmp, name, level| {
	deflated = Deflate.compress(corpus, level) ? |_| Exit(1)
	container = gzip_wrap(deflated, Crc32.checksum(corpus), corpus.len())
	gz_path = tmp.join("roc_deflate_harness_ours.gz")
	Path.write_bytes!(gz_path, container) ? |_| Exit(1)
	gz_os = OsStr.from_raw(Path.to_raw(gz_path))
	res = match Cmd.new(OsStr.from_str("gzip")).args([OsStr.from_str("-dc"), gz_os]).exec_output_bytes!() {
		Ok(r) => r
		Err(NonZeroExitCodeB({ exit_code, stderr_bytes, .. })) => {
			Stdout.line!("  ${name}: gzip exit ${exit_code.to_str()}: ${Str.from_utf8_lossy(stderr_bytes)}")?
			Err(Exit(1))?
		}
		Err(_) => Err(Exit(1))?
	}
	Path.delete!(gz_path) ? |_| Exit(1)
	if res.stdout_bytes == corpus {
		Stdout.line!("  ${name}: gzip decoded our stream byte-identically")
	} else {
		Stdout.line!("  ${name}: MISMATCH")?
		Err(Exit(1))
	}
}

# Compress the corpus with real gzip, strip the container, and confirm our
# decompressor reproduces the corpus from the raw DEFLATE stream.
check_reverse! : List(U8), OsStr, Str => Try({}, [Exit(I32), StdoutErr(IOErr)])
check_reverse! = |corpus, corpus_os, level| {
	res = Cmd.new(OsStr.from_str("gzip")).args([OsStr.from_str("-n"), OsStr.from_str(level), OsStr.from_str("-c"), corpus_os]).exec_output_bytes!() ? |_| Exit(1)
	# gzip member: 10-byte header, raw DEFLATE, then CRC32 + length (8 bytes).
	raw = res.stdout_bytes.drop_first(10).drop_last(8)
	decoded = Deflate.decompress(raw) ? |_| Exit(1)
	if decoded == corpus {
		Stdout.line!("  gzip ${level}: we inflated gzip's stream byte-identically")
	} else {
		Stdout.line!("  gzip ${level}: MISMATCH")?
		Err(Exit(1))
	}
}

# A minimal gzip member: header, the raw DEFLATE stream, then CRC32 and
# length (mod 2^32) of the uncompressed data, both little-endian.
gzip_wrap : List(U8), U32, U64 -> List(U8)
gzip_wrap = |deflated, crc, len| {
	header = [0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 255]
	with_stream = deflated.fold(header, |acc, byte| acc.append(byte))
	with_crc = append_u32_le(with_stream, crc)
	append_u32_le(with_crc, len.to_u32_wrap())
}

append_u32_le : List(U8), U32 -> List(U8)
append_u32_le = |bytes, value|
	bytes
		.append(value.bitwise_and(0xFF).to_u8_wrap())
		.append(value.shr_wrap(8).bitwise_and(0xFF).to_u8_wrap())
		.append(value.shr_wrap(16).bitwise_and(0xFF).to_u8_wrap())
		.append(value.shr_wrap(24).bitwise_and(0xFF).to_u8_wrap())
