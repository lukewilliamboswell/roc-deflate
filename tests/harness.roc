## Interop tests against real gzip and libdeflate, in-process.
##
## A deterministic corpus is generated in memory and written to a temp file.
## Forward: our DEFLATE stream is wrapped in a gzip container and handed to
## real `gzip -d`, whose output must equal the corpus. Reverse: real `gzip`
## compresses the corpus, and our decompressor must reproduce it from the raw
## DEFLATE stream (gzip's 10-byte header and 8-byte trailer removed). Passing
## both directions proves standard compliance against an independent codec.
##
## The compressor is a port of libdeflate's, so its output must also be the
## same bytes as libdeflate's own `libdeflate-gzip` at every level from 1 to
## 12, on the corpus and on inputs whose lengths sit where some level changes
## behavior. Every level also round-trips those inputs and stays within
## `compress_bound`. The decoder is then held to its error contract: every
## truncation of a stream reports `UnexpectedEnd`, and flipping any single bit
## of a stream decodes or fails but never crashes.
##
## gzip and libdeflate-gzip only ever read a file and write to stdout (which
## we capture) or next to the file, so no large payload is fed to a stdin and
## there is no pipe-buffer deadlock. The flake's dev shell provides both:
##
##     nix develop -c roc tests/harness.roc
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
	deflate: "../package/main.roc",
	crc32: "https://github.com/niclas-ahden/roc-crc32/releases/download/1.0.3/H7PGfAdWAHVHcw2RHGRkXzEZzzNjhmYm8vcDMmYvogw7.tar.zst",
}

import pf.Stdout
import pf.Cmd
import pf.Path
import pf.Env
import pf.System
import pf.IOErr
import pf.OsStr
import deflate.Deflate
import crc32.Crc32
import TextGen

main! = |args| {
	# `+ args.len()` keeps the corpus size runtime-dependent. With a literal
	# length, TextGen.generate and the Deflate.compress calls below become fully
	# compile-time-known, and the compiler evaluates the whole compression at
	# build time, which balloons to ~45 GB and OOM-kills the build. args.len()
	# is 0 with no arguments, so the corpus stays deterministic across runs.
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
	for level in Deflate.Level.all {
		check_roundtrip!(corpus, level)?
	}

	# CI's Windows runners have no libdeflate-gzip to install, so Windows skips
	# the comparison. Everywhere else a missing libdeflate-gzip is a failure.
	libdeflate =
		match System.target!().os() {
			Windows(_) => False
			_ => True
		}

	if libdeflate {
		Stdout.line!("== libdeflate: our streams are the same bytes as libdeflate's")?
		# libdeflate-gzip has no level 0.
		for level in Deflate.Level.all.drop_first(1) {
			check_identical!(corpus, corpus_os, level)?
		}

		Stdout.line!("== edge lengths: every level round-trips, stays in bound, and matches libdeflate")?
	} else {
		Stdout.line!("== libdeflate: skipped on Windows")?
		Stdout.line!("== edge lengths: every level round-trips and stays in bound")?
	}
	check_edges!(tmp, args.len(), libdeflate)?

	Stdout.line!("== decoder errors")?
	check_decoder_errors!(List.sublist(corpus, { start: 0, len: 4096 }), tmp)?

	Path.delete!(corpus_path) ? |_| Exit(1)
	Stdout.line!("All interop checks passed")?
	Ok({})
}

# Compress the corpus with libdeflate's own gzip at the same level, and confirm
# our raw stream is the same bytes as the one inside libdeflate's container.
check_identical! : List(U8), OsStr, Deflate.Level => Try({}, [Exit(I32), Interrupted, StdoutErr(IOErr)])
check_identical! = |corpus, corpus_os, level| {
	theirs = libdeflate_gzip!([OsStr.from_str("-c"), corpus_os], level.to_u64())?.drop_first(10).drop_last(8)
	ours = Deflate.compress(corpus, level)
	if ours == theirs {
		Stdout.line!("  level ${level.to_u64().to_str()}: identical, ${ours.len().to_str()} bytes")
	} else {
		Stdout.line!("  level ${level.to_u64().to_str()}: DIFFERS, ours ${ours.len().to_str()} bytes, libdeflate's ${theirs.len().to_str()}")?
		Err(Exit(1))
	}
}

# Run libdeflate-gzip at a level and return what it wrote to stdout.
libdeflate_gzip! : List(OsStr), U64 => Try(List(U8), [Exit(I32), Interrupted, StdoutErr(IOErr)])
libdeflate_gzip! = |arguments, level| {
	output = match Cmd.new(OsStr.from_str("libdeflate-gzip")).args([OsStr.from_str("-${level.to_str()}")].concat(arguments)).run!() {
		Ok(o) => o
		Err(_) => {
			Stdout.line!("  libdeflate-gzip did not run. The flake's dev shell provides it: nix develop -c ./tests.roc")?
			return Err(Exit(1))
		}
	}
	match output.status {
		Exited(0) => Ok(output.stdout_bytes)
		status => {
			Stdout.line!("  libdeflate-gzip -${level.to_str()}: ${Str.inspect(status)}: ${output.stderr_utf8_lossy()}")?
			Err(Exit(1))
		}
	}
}

# Lengths where some level changes behavior: every length up to 64, which
# takes in the shortest inputs the hashes can read and each level's
# passthrough limit, then the minimum block length, level 1's block length,
# the soft maximum block length and a long match past it, the longest block
# the near-optimal parser can be handed (a remainder shorter than the minimum
# block length is folded into the block before it), and two of those.
#
# `extra` is 0, but coming from the command line it keeps every input built
# from these lengths runtime-dependent, for the reason given in main!.
edge_lengths : U64 -> List(U64)
edge_lengths = |extra|
	List.repeat(0.U64, 65)
		.map_with_index(|_, i| i)
		.concat([255, 256, 257, 258, 259, 260, 261, 262, 263, 4999, 5000, 5001, 32760, 32761, 32762, 32763, 32764, 32765, 32766, 32767, 32768, 32769, 32770, 32771, 32772, 32773, 32774, 32775, 32776, 65535, 65536, 65537, 300000, 300258, 304742, 304743, 304999, 305000, 305001, 609998])
		.map(|len| len + extra)

# Bytes from a 64-bit LCG, which no level can compress.
noise : U64 -> List(U8)
noise = |len| {
	var $out = List.with_capacity(len)
	var $state = 0x2545F4914F6CDD1D.U64
	while List.len($out) < len {
		$state = $state.times_wrap(6364136223846793005).plus_wrap(1442695040888963407)
		$out = List.append($out, $state.shr_zf_wrap(56).to_u8_wrap())
	}
	$out
}

# Every input in the edge sweep: each length of zeros, noise, text, runs, and
# short periodic patterns, so each length meets the parsers on runs, on nothing to
# match, on ordinary matches, and on one short offset over and over.
EdgeCase : { name : Str, bytes : List(U8) }

edge_cases : U64 -> List(EdgeCase)
edge_cases = |extra| {
	lengths = edge_lengths(extra)
	longest = lengths.fold(0, |most, len| most.max(len))
	sources = [
		{ shape: "zeros", bytes: List.repeat(0.U8, longest) },
		# Runs cover every byte value and end in changing bytes, exercising
		# the hash prefixes that straddle a repeated match's boundary.
		{ shape: "runs", bytes: List.repeat(0.U8, longest).map_with_index(|_, i| if i % 263 < 258 { (i // 263 % 256).to_u8_wrap() } else { (i % 251).to_u8_wrap() }) },
		{ shape: "noise", bytes: noise(longest) },
		{ shape: "text", bytes: TextGen.generate(7, longest) },
		{ shape: "period2", bytes: List.repeat(0.U8, longest).map_with_index(|_, i| (97 + i % 2).to_u8_wrap()) },
		{ shape: "pattern", bytes: List.repeat(0.U8, longest).map_with_index(|_, i| (97 + i % 7).to_u8_wrap()) },
	]
	var $cases = []
	for source in sources {
		for len in lengths {
			$cases = $cases.append({ name: "${source.shape}_${len.to_str()}", bytes: List.sublist(source.bytes, { start: 0, len }) })
		}
	}
	$cases
}

# Compress every edge case at every level. libdeflate-gzip compresses the
# whole set in one run per level, writing each file's `.gz` next to it.
# libdeflate-gzip has no level 0, so level 0 is held to the round trip and
# the bound only, and so is every level when `libdeflate` is False.
check_edges! : Path.Path, U64, Bool => Try({}, [Exit(I32), Interrupted, StdoutErr(IOErr)])
check_edges! = |tmp, extra, libdeflate| {
	dir = tmp.join("roc_deflate_harness_edges")
	Path.create_all!(dir) ? |_| Exit(1)
	cases = edge_cases(extra)
	for c in cases {
		Path.write_bytes!(dir.join(c.name), c.bytes) ? |_| Exit(1)
	}
	file_args = cases.map(|c| OsStr.from_raw(Path.to_raw(dir.join(c.name))))

	for level in Deflate.Level.all {
		n = level.to_u64()
		compare = libdeflate and n >= 1
		if compare {
			_ = libdeflate_gzip!([OsStr.from_str("-k"), OsStr.from_str("-f")].concat(file_args), n)?
		} else {}
		for c in cases {
			ours = Deflate.compress(c.bytes, level)
			if Deflate.decompress(ours) != Ok(c.bytes) {
				Stdout.line!("  level ${n.to_str()}, ${c.name}: does not round-trip")?
				return Err(Exit(1))
			} else {}
			if List.len(ours) > Deflate.compress_bound(List.len(c.bytes)) {
				Stdout.line!("  level ${n.to_str()}, ${c.name}: ${List.len(ours).to_str()} bytes is over compress_bound")?
				return Err(Exit(1))
			} else {}
			if compare {
				gz = Path.read_bytes!(dir.join("${c.name}.gz")) ? |_| Exit(1)
				if ours != gz.drop_first(10).drop_last(8) {
					Stdout.line!("  level ${n.to_str()}, ${c.name}: DIFFERS from libdeflate")?
					return Err(Exit(1))
				} else {}
			} else {}
		}
		Stdout.line!("  level ${n.to_str()}: ${List.len(cases).to_str()} inputs")?
	}
	Path.delete_all!(dir) ? |_| Exit(1)
	Ok({})
}

# How a decode came out, without printing what it decoded to.
outcome : Try(List(U8), [CorruptData, UnexpectedEnd]) -> Str
outcome = |result|
	match result {
		Ok(_) => "Ok"
		Err(CorruptData) => "CorruptData"
		Err(UnexpectedEnd) => "UnexpectedEnd"
	}

# Hold the decoder to its error contract on streams of a short sample, ours at
# four levels and real gzip's: every proper prefix of a stream is a truncation
# and must report UnexpectedEnd, and a stream with any single bit flipped may
# decode to something else or fail, but a crash ends this program and fails
# the run. Then check decompress_into appends without reaching into what it
# was handed.
check_decoder_errors! : List(U8), Path.Path => Try({}, [Exit(I32), Interrupted, StdoutErr(IOErr)])
check_decoder_errors! = |sample, tmp| {
	sample_path = tmp.join("roc_deflate_harness_sample.bin")
	Path.write_bytes!(sample_path, sample) ? |_| Exit(1)
	gzip_out = Cmd.new(OsStr.from_str("gzip")).args([OsStr.from_str("-n"), OsStr.from_str("-6"), OsStr.from_str("-c"), OsStr.from_raw(Path.to_raw(sample_path))]).run!() ? |_| Exit(1)
	gzip_res = gzip_out.require_success() ? |_| Exit(1)
	Path.delete!(sample_path) ? |_| Exit(1)
	streams = [
		{ name: "level 0", bytes: Deflate.compress(sample, 0) },
		{ name: "level 1", bytes: Deflate.compress(sample, 1) },
		{ name: "level 6", bytes: Deflate.compress(sample, 6) },
		{ name: "level 12", bytes: Deflate.compress(sample, 12) },
		{ name: "gzip -6", bytes: gzip_res.stdout_bytes.drop_first(10).drop_last(8) },
	]

	for stream in streams {
		var $len = 0.U64
		while $len < List.len(stream.bytes) {
			result = Deflate.decompress(List.sublist(stream.bytes, { start: 0, len: $len }))
			if outcome(result) != "UnexpectedEnd" {
				Stdout.line!("  ${stream.name}: the first ${$len.to_str()} bytes decode to ${outcome(result)}, not UnexpectedEnd")?
				return Err(Exit(1))
			} else {}
			$len = $len + 1
		}
		Stdout.line!("  ${stream.name}: all ${List.len(stream.bytes).to_str()} truncations report UnexpectedEnd")?
	}

	for stream in streams {
		var $ok = 0.U64
		var $corrupt = 0.U64
		var $short = 0.U64
		var $bit = 0.U64
		while $bit < List.len(stream.bytes) * 8 {
			at = $bit // 8
			byte = List.get(stream.bytes, at) ?? 0
			flipped = List.set(stream.bytes, at, byte.bitwise_xor(1.U8.shl_wrap(($bit % 8).to_u8_wrap()))) ?? stream.bytes
			match outcome(Deflate.decompress(flipped)) {
				"Ok" => { $ok = $ok + 1 }
				"CorruptData" => { $corrupt = $corrupt + 1 }
				_ => { $short = $short + 1 }
			}
			$bit = $bit + 1
		}
		Stdout.line!("  ${stream.name}: every bit flipped once: ${$ok.to_str()} decode, ${$corrupt.to_str()} CorruptData, ${$short.to_str()} UnexpectedEnd")?
	}

	prefix = [1, 2, 3]
	level6 = Deflate.compress(sample, 6)
	if Deflate.decompress_into(level6, prefix) == Ok(prefix.concat(sample)) {
		Stdout.line!("  decompress_into appends after what out holds")
	} else {
		Stdout.line!("  decompress_into: MISMATCH")?
		Err(Exit(1))
	}
}

# Compress and then decompress with our own code, and confirm the bytes come
# back unchanged.
check_roundtrip! : List(U8), Deflate.Level => Try({}, [Exit(I32), Interrupted, StdoutErr(IOErr)])
check_roundtrip! = |corpus, level| {
	deflated = Deflate.compress(corpus, level)
	back = Deflate.decompress(deflated) ? |_| Exit(1)
	if back == corpus {
		Stdout.line!("  level ${level.to_u64().to_str()}: round-tripped ${deflated.len().to_str()} bytes")
	} else {
		Stdout.line!("  level ${level.to_u64().to_str()}: MISMATCH")?
		Err(Exit(1))
	}
}

# Compress with our encoder, wrap in a gzip member, and confirm real gzip
# decodes it back to the exact corpus.
check_forward! : List(U8), Path.Path, Str, Deflate.Level => Try({}, [Exit(I32), Interrupted, StdoutErr(IOErr)])
check_forward! = |corpus, tmp, name, level| {
	deflated = Deflate.compress(corpus, level)
	container = gzip_wrap(deflated, Crc32.checksum(corpus), corpus.len())
	gz_path = tmp.join("roc_deflate_harness_ours.gz")
	Path.write_bytes!(gz_path, container) ? |_| Exit(1)
	gz_os = OsStr.from_raw(Path.to_raw(gz_path))
	res = Cmd.new(OsStr.from_str("gzip")).args([OsStr.from_str("-dc"), gz_os]).run!() ? |_| Exit(1)
	match res.status {
		Exited(0) => {}
		status => {
			Stdout.line!("  ${name}: gzip ${Str.inspect(status)}: ${res.stderr_utf8_lossy()}")?
			return Err(Exit(1))
		}
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
check_reverse! : List(U8), OsStr, Str => Try({}, [Exit(I32), Interrupted, StdoutErr(IOErr)])
check_reverse! = |corpus, corpus_os, level| {
	output = Cmd.new(OsStr.from_str("gzip")).args([OsStr.from_str("-n"), OsStr.from_str(level), OsStr.from_str("-c"), corpus_os]).run!() ? |_| Exit(1)
	res = output.require_success() ? |_| Exit(1)
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
