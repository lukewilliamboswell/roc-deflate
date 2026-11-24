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
## The gzip container is held to the same tools: real gzip's files, with and
## without a file name and as several members, decode to the corpus under
## `Gzip.decompress`, and `Gzip.compress`'s files decode under real `gzip -d`
## and are the same bytes, header and trailer included, as `libdeflate-gzip`
## writes, on the corpus and across the edge sweep. On a real gzip file every
## truncation reports `UnexpectedEnd`, and a bit flipped anywhere either
## fails or still gives exactly the original, never other bytes.
##
## gzip and libdeflate-gzip only ever read a file and write to stdout (which
## we capture) or next to the file, so no large payload is fed to a stdin and
## there is no pipe-buffer deadlock. The flake's dev shell provides both:
##
##     nix develop -c roc tests/harness.roc
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	deflate: "../package/main.roc",
	crc32: "https://github.com/niclas-ahden/roc-crc32/releases/download/2.0.1/GVgp4MNmCBjdtJg8j2gBdsrdsKKyx4huzRz7ZtbRaYvJ.tar.zst",
}

import pf.Stdout
import pf.Cmd
import pf.Path
import pf.Env
import pf.System
import pf.IOErr
import pf.OsStr
import deflate.Deflate
import deflate.Gzip
import crc32.Crc32
import TextGen
import "../fuzz/bomb.deflate" as bomb : List(U8)

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

	Stdout.line!("== gzip files: real gzip reads ours and we read real gzip's")?
	check_gzip!(corpus, corpus_os, tmp, libdeflate)?

	# fuzz/inflate_bomb.roc decodes a pinned stream, so check it is still what
	# level 6 makes of 8 MiB of zeros. `+ args.len()` keeps the compression out
	# of the build, as with the corpus above.
	Stdout.line!("== fuzz fixture")?
	if Deflate.compress(List.repeat(0, 8_388_608 + args.len()), 6) != bomb {
		Stdout.line!("  fuzz/bomb.deflate is not Deflate.compress(List.repeat(0, 8_388_608), 6)")?
		return Err(Exit(1))
	}
	Stdout.line!("  fuzz/bomb.deflate is level 6 on 8 MiB of zeros")?

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
			# The raw stream is the middle of the gzip file, which
			# Gzip.compress builds with Deflate.compress_into, so one
			# compression checks both the stream and the file.
			ours_gz = Gzip.compress(c.bytes, level)
			ours = List.sublist(ours_gz, { start: 10, len: List.len(ours_gz) - 18 })
			if Deflate.decompress(ours, {}) != Ok(c.bytes) {
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
				if ours_gz != gz {
					Stdout.line!("  level ${n.to_str()}, ${c.name}: the gzip file DIFFERS from libdeflate-gzip's")?
					return Err(Exit(1))
				} else {}
				if Gzip.decompress(gz, {}) != Ok(c.bytes) {
					Stdout.line!("  level ${n.to_str()}, ${c.name}: libdeflate-gzip's file does not decode to the input")?
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
outcome : Try(List(U8), [CorruptData, UnexpectedEnd, OutputLimitExceeded]) -> Str
outcome = |result|
	match result {
		Ok(_) => "Ok"
		Err(CorruptData) => "CorruptData"
		Err(UnexpectedEnd) => "UnexpectedEnd"
		Err(OutputLimitExceeded) => "OutputLimitExceeded"
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
			result = Deflate.decompress(List.sublist(stream.bytes, { start: 0, len: $len }), {})
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
			match outcome(Deflate.decompress(flipped, {})) {
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
	if Deflate.decompress_into(level6, prefix, {}) == Ok(prefix.concat(sample)) {
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
	back = Deflate.decompress(deflated, {}) ? |_| Exit(1)
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
	decoded = Deflate.decompress(raw, {}) ? |_| Exit(1)
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

# How a gzip decode came out, without printing what it decoded to.
gzip_outcome : Try(List(U8), Gzip.GzipError) -> Str
gzip_outcome = |result|
	match result {
		Ok(_) => "Ok"
		Err(err) => Str.inspect(err)
	}

# Run real gzip with these arguments and return what it wrote to stdout.
gzip! : List(Str) => Try(List(U8), [Exit(I32), Interrupted, StdoutErr(IOErr)])
gzip! = |arguments| {
	output = Cmd.new(OsStr.from_str("gzip")).args(arguments.map(OsStr.from_str)).run!() ? |_| Exit(1)
	match output.status {
		Exited(0) => Ok(output.stdout_bytes)
		status => {
			Stdout.line!("  gzip ${Str.join_with(arguments, " ")}: ${Str.inspect(status)}: ${output.stderr_utf8_lossy()}")?
			Err(Exit(1))
		}
	}
}

# The gzip container in both directions against real gzip, whole files
# against libdeflate-gzip, the trailer's CRC-32 against niclas-ahden/roc-crc32,
# and the reader's error contract on a real gzip file.
check_gzip! : List(U8), OsStr, Path.Path, Bool => Try({}, [Exit(I32), Interrupted, StdoutErr(IOErr)])
check_gzip! = |corpus, corpus_os, tmp, libdeflate| {
	corpus_arg = OsStr.display(corpus_os)
	sample = List.sublist(corpus, { start: 0, len: 100_000 })
	sample_path = tmp.join("roc_deflate_harness_gzip_sample.bin")
	Path.write_bytes!(sample_path, sample) ? |_| Exit(1)
	sample_arg = Path.display(sample_path)

	# Theirs to ours. Without -n, gzip writes the file name and time, so the
	# header has an optional field to read past.
	for args in [["-n", "-1"], ["-n", "-6"], ["-9"]] {
		gz = gzip!(args.concat(["-c", corpus_arg]))?
		if Gzip.decompress(gz, {}) != Ok(corpus) {
			Stdout.line!("  gzip ${Str.join_with(args, " ")}: MISMATCH")?
			return Err(Exit(1))
		} else {}
		Stdout.line!("  gzip ${Str.join_with(args, " ")}: we read its ${gz.len().to_str()}-byte file")?
	}

	# Several members, as `cat a.gz b.gz` makes, decode to their outputs one
	# after another, as gunzip gives them, and the bound counts them all.
	theirs_two = gzip!(["-c", sample_arg])?.concat(gzip!(["-n", "-6", "-c", corpus_arg])?)
	both = sample.concat(corpus)
	if Gzip.decompress(theirs_two, {}) != Ok(both) {
		Stdout.line!("  two gzip members: MISMATCH")?
		return Err(Exit(1))
	} else {}
	if Gzip.decompress(theirs_two, { max_output: List.len(both) - 1 }) != Err(OutputLimitExceeded) {
		Stdout.line!("  two gzip members: the bound did not count both")?
		return Err(Exit(1))
	} else {}
	Stdout.line!("  two gzip members: we read them as one output, within one bound")?

	# Ours to theirs, one member and several.
	ours_path = tmp.join("roc_deflate_harness_ours_gzip.gz")
	ours_arg = Path.display(ours_path)
	for level in [0, 1, 6, 9, 12] {
		Path.write_bytes!(ours_path, Gzip.compress(corpus, level)) ? |_| Exit(1)
		if gzip!(["-dc", ours_arg])? != corpus {
			Stdout.line!("  Gzip.compress level ${level.to_u64().to_str()}: gzip -d gave other bytes")?
			return Err(Exit(1))
		} else {}
		Stdout.line!("  Gzip.compress level ${level.to_u64().to_str()}: gzip -d reads it")?
	}
	Path.write_bytes!(ours_path, Gzip.compress(sample, 1).concat(Gzip.compress(corpus, 6))) ? |_| Exit(1)
	if gzip!(["-dc", ours_arg])? != both {
		Stdout.line!("  Gzip.compress, two members: gzip -d gave other bytes")?
		return Err(Exit(1))
	} else {}
	Stdout.line!("  Gzip.compress, two members: gzip -d concatenates them")?
	Path.delete!(ours_path) ? |_| Exit(1)

	# The CRC-32 is the package's own, so check the trailer against an
	# independent implementation.
	ours_gz = Gzip.compress(corpus, 6)
	trailer = List.sublist(ours_gz, { start: List.len(ours_gz) - 8, len: 8 })
	if trailer != append_u32_le(append_u32_le([], Crc32.checksum(corpus)), List.len(corpus).to_u32_wrap()) {
		Stdout.line!("  the trailer is not niclas-ahden/roc-crc32's CRC-32 and the size")?
		return Err(Exit(1))
	} else {}
	Stdout.line!("  the trailer is niclas-ahden/roc-crc32's CRC-32 and the size")?

	if libdeflate {
		for level in Deflate.Level.all.drop_first(1) {
			theirs = libdeflate_gzip!([OsStr.from_str("-c"), corpus_os], level.to_u64())?
			if Gzip.compress(corpus, level) != theirs {
				Stdout.line!("  level ${level.to_u64().to_str()}: the gzip file DIFFERS from libdeflate-gzip's")?
				return Err(Exit(1))
			} else {}
		}
		Stdout.line!("  levels 1 to 12: the same bytes as libdeflate-gzip's files")?
	} else {}

	# The error contract, on a real gzip file with a file name: every
	# truncation is UnexpectedEnd, and a bit flipped anywhere fails or, in a
	# field nothing checks (the time, FTEXT, the extra flags, the OS, the
	# name), still gives exactly the original, never other bytes.
	small = List.sublist(corpus, { start: 0, len: 4096 })
	Path.write_bytes!(sample_path, small) ? |_| Exit(1)
	named = gzip!(["-6", "-c", sample_arg])?
	Path.delete!(sample_path) ? |_| Exit(1)
	var $len = 0.U64
	while $len < List.len(named) {
		result = Gzip.decompress(List.sublist(named, { start: 0, len: $len }), {})
		if gzip_outcome(result) != "UnexpectedEnd" {
			Stdout.line!("  the first ${$len.to_str()} bytes of gzip's file decode to ${gzip_outcome(result)}, not UnexpectedEnd")?
			return Err(Exit(1))
		} else {}
		$len = $len + 1
	}
	Stdout.line!("  all ${List.len(named).to_str()} truncations of gzip's file report UnexpectedEnd")?

	var $same = 0.U64
	var $failed = 0.U64
	var $crc = 0.U64
	var $bit = 0.U64
	while $bit < List.len(named) * 8 {
		at = $bit // 8
		byte = List.get(named, at) ?? 0
		flipped = List.set(named, at, byte.bitwise_xor(1.U8.shl_wrap(($bit % 8).to_u8_wrap()))) ?? named
		match Gzip.decompress(flipped, {}) {
			Ok(bytes) =>
				if bytes == small {
					$same = $same + 1
				} else {
					Stdout.line!("  flipping bit ${$bit.to_str()} of gzip's file decodes to other bytes")?
					return Err(Exit(1))
				}
			Err(CrcMismatch) => {
				$crc = $crc + 1
			}
			Err(_) => {
				$failed = $failed + 1
			}
		}
		$bit = $bit + 1
	}
	Stdout.line!("  every bit of gzip's file flipped once: ${$same.to_str()} still the original, ${$crc.to_str()} CrcMismatch, ${$failed.to_str()} other errors")
}
