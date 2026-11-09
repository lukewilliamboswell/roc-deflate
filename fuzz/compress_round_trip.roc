app [target] {
	deflate: "../package/main.roc",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.5.0/9WT86CuwM7ZJBSs8iTd1jLyrUFTTiGp5hcJE63TwswGE.tar.zst",
}

import fuzz.Fuzz
import deflate.Deflate
import Plaintext

## Structured plaintext, a level from 0 to 12, and where to cut the output
## off when it is decompressed.
Input := { pieces : List(Plaintext.Piece), level : U64, cut : U64 }.{
	parser_for : _
	encoder_for : _

	generator_for : Fuzz.FuzzEncoding -> Fuzz.Generator(Input)
	generator_for = |_| {
		{
			pieces: Fuzz.list({ literal: Fuzz.bytes, back: Fuzz.u64_in(0, 65_535), len: Fuzz.u64_in(0, 1_200) }.Fuzz, 32),
			level: Fuzz.u64_in(0, 12),
			cut: Fuzz.u64,
		}.Fuzz
	}
}

## Every level compresses any plaintext to a stream that decompresses back to
## it, no longer than `compress_bound`, the same bytes twice, and the same
## bytes `compress_into` appends to what its list holds. Decompressed under a
## bound anywhere from zero to past its length, the stream gives the
## plaintext when it fits and `OutputLimitExceeded` when it does not.
##
## Memory ratchets, which only ever move down: compressing at a level holds at
## most `compress_ceiling(level, len)` bytes live beyond what it started with,
## and requests at most `short_input_requested_ceiling(level)` bytes for an
## input of at most 256 bytes, and decompressing with the truthful declared size never reallocates and
## holds at most `decompress_fixed_ceiling` bytes beyond the plaintext.
## Raising a ceiling needs a cause recorded in the pull request.
test! : Input => Fuzz.Outcome
test! = |input| {
	level = match Deflate.Level.from_u64(input.level) {
		Ok(chosen) => chosen
		# Encoded inputs bypass the generator, so its range is checked here too.
		Err(OutOfRange) => return Fuzz.reject
	}
	if List.len(input.pieces) > 32 or input.pieces.any(|p| p.len > 1_200) {
		return Fuzz.reject
	}
	plain = Plaintext.expand(input.pieces)
	len = List.len(plain)
	{ value: compressed, stats } = Fuzz.measure!("compress", || Deflate.compress(plain, level))
	if stats.peak_live_bytes - stats.entry_live_bytes > compress_ceiling(input.level, len) {
		crash "compress held more live memory than its level's ceiling"
	}
	if len <= 256 and stats.requested_bytes > short_input_requested_ceiling(input.level) {
		crash "compress requested more for a short input than its level's ceiling"
	}
	{ value: decoded, stats: decode_stats } = Fuzz.measure!("decompress-declared", || Deflate.decompress(compressed, { max_output: len, expected_size: Declared(len) }))
	if decoded != Ok(plain) {
		crash "the stream did not decompress back to the plaintext"
	}
	if decode_stats.reallocs > 0 or decode_stats.peak_live_bytes - decode_stats.entry_live_bytes > decompress_fixed_ceiling + len {
		crash "decompressing with the truthful declared size reallocated or held more than the plaintext"
	}
	max_output = input.cut % (len + 2)
	expected = if len <= max_output {
		Ok(plain)
	} else {
		Err(OutputLimitExceeded)
	}
	if Deflate.decompress(compressed, { max_output: max_output }) != expected {
		crash "the bound did not cut the output off exactly at its length"
	}
	if List.len(compressed) > Deflate.compress_bound(len) {
		crash "the stream is longer than compress_bound"
	}
	if Deflate.compress(plain, level) != compressed {
		crash "compressing the same plaintext twice disagreed"
	}
	if Deflate.compress_into(plain, level, [1, 2, 3]) != List.concat([1, 2, 3], compressed) {
		crash "compress_into appended a different stream"
	}
	Fuzz.keep
}

# Measured on nightly-2026-11-07-ad3a5d2 over a 2,127-input corpus of up to
# 12 KB. The fixed part is each level's matchfinder tables, which keep
# libdeflate's sizes: 128 KiB at level 1, 256 KiB at levels 2 to 9 and
# 512 KiB at levels 10 to 12. The rest is linear in the input: the output,
# the sequence store and, at levels 10 to 12, the match cache and the node
# list. Before those were sized to the input, a 1 KB input held 687 KB live
# at level 6 and 8.98 MB at level 12.
compress_ceiling : U64, U64 -> U64
compress_ceiling = |level, len|
	if level == 0 {
		64 + 2 * len
	} else if level == 1 {
		155_000 + 4 * len
	} else if level <= 9 {
		286_000 + 4 * len
	} else {
		560_000 + 32 * len
	}

# The most bytes compressing an input of at most 256 bytes requests, measured
# alongside `compress_ceiling` over 2,352 inputs (at most 172,128, 303,475 and
# 669,218): the tables, and little else; levels 10 to 12 vary with the number
# of optimization passes. Short inputs are
# where buffers sized for the longest block used to cost the most.
short_input_requested_ceiling : U64 -> U64
short_input_requested_ceiling = |level|
	if level == 0 {
		300
	} else if level == 1 {
		173_000
	} else if level <= 9 {
		304_000
	} else {
		680_000
	}

# Measured on nightly-2026-11-07-ad3a5d2 alongside `compress_ceiling`, over
# 2,127 inputs: at most 12,956 bytes beyond the plaintext, the decoder's state.
decompress_fixed_ceiling : U64
decompress_fixed_ceiling = 13_500

text : List(U8)
text = "the cat, the cow, the crow, then the cricket saw the cow again and again".to_utf8()

example : Str, U64, List(Plaintext.Piece) -> Fuzz.Example(Input)
example = |name, level, pieces| Fuzz.example({ name, revision: "1", make: || Input.{ pieces, level, cut: 0 } })

target = Fuzz.target_with!({
	name: "compress-round-trip",
	examples: [
		example("empty-0", 0, []),
		example("empty-12", 12, []),
		example("text-1", 1, [{ literal: text, back: 30, len: 1_000 }]),
		example("text-6", 6, [{ literal: text, back: 30, len: 1_000 }, { literal: text, back: 7, len: 200 }]),
		example("text-12", 12, [{ literal: text, back: 30, len: 1_000 }, { literal: text, back: 7, len: 200 }]),
		example("run-9", 9, [{ literal: [0], back: 0, len: 1_200 }]),
	],
	generator: Input.generator_for(Default),
	test!,
	show: |input| Str.inspect(input),
})
