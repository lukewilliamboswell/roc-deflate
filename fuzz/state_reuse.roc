app [target] {
	deflate: "../package/main.roc",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.5.0/9WT86CuwM7ZJBSs8iTd1jLyrUFTTiGp5hcJE63TwswGE.tar.zst",
}

import fuzz.Fuzz
import deflate.Deflate
import Plaintext

## Up to eight structured plaintexts, compressed in turn at one level.
Input := { texts : List(List(Plaintext.Piece)), level : U64 }.{
	parser_for : _
	encoder_for : _

	generator_for : Fuzz.FuzzEncoding -> Fuzz.Generator(Input)
	generator_for = |_| {
		{
			texts: Fuzz.list(Fuzz.list({ literal: Fuzz.bytes, back: Fuzz.u64_in(0, 65_535), len: Fuzz.u64_in(0, 1_200) }.Fuzz, 8), max_texts),
			level: Fuzz.u64_in(0, 12),
		}.Fuzz
	}
}

## Streams pushed through one `Compressor` are the same bytes `compress`
## gives each on its own, and streams pushed through one `Decoder` decode to
## what `decompress` gives each on its own.
##
## Allocation ratchets, which only ever move down: the state is allocated
## once, not once per stream. Through one compressor every stream but the
## first allocates none of its level's fixed matchfinder tables, and through
## one decoder, once its tables are built, a stream allocates its output and
## only the few small zeroed lists each dynamic block takes fresh, far less
## than one decode table.
## Raising a ceiling needs a cause recorded in the pull request.
test! : Input => Fuzz.Outcome
test! = |input| {
	level = match Deflate.Level.from_u64(input.level) {
		Ok(chosen) => chosen
		# Encoded inputs bypass the generator, so its ranges are checked here too.
		Err(OutOfRange) => return Fuzz.reject
	}
	if List.len(input.texts) > max_texts or input.texts.any(|pieces| List.len(pieces) > 8 or pieces.any(|p| p.len > 1_200)) {
		return Fuzz.reject
	}
	texts = input.texts.map(Plaintext.expand)

	{ value: reused, stats: reused_stats } = Fuzz.measure!("compress-with", || compress_all(Deflate.compressor(level), texts))
	{ value: independent, stats: independent_stats } = Fuzz.measure!("compress-independent", || texts.map(|text| Deflate.compress(text, level)))
	if reused != independent {
		crash "compress_with gave different bytes than compress"
	}
	# Inputs this short are stored without touching the tables.
	compressed = texts.count_if(|text| List.len(text) > passthrough(input.level))
	# The input-sized buffers can grow differently from a reused base than
	# from a fresh one, so only the fixed tables are counted.
	saved = compressed.max(1) - 1
	if reused_stats.allocs + saved * fixed_tables(input.level) > independent_stats.allocs {
		crash "a compressor allocated its tables more than once"
	}

	# The first pass builds the decoder's tables; the second measures a warm
	# decoder.
	# Each stream declares its true size, so its output never grows and a
	# stream's only allocation is its output.
	streams = List.map2(reused, texts, |stream, text| { stream, size: List.len(text) })
	warm = decompress_all(Deflate.decoder(), streams).decoder
	{ value: decoded, stats: decoded_stats } = Fuzz.measure!("decompress-with", || decompress_all(warm, streams).outputs)
	if decoded != texts.map(|plain| Ok(plain)) {
		crash "decompress_with did not give back the plaintexts"
	}
	outputs_bytes = texts.map(|text| List.len(text) + output_scratch).sum()
	if decoded_stats.reallocs > 0 or decoded_stats.requested_bytes > outputs_bytes + warm_decode_overhead_ceiling * List.len(texts) + 64 {
		crash "a warm decoder allocated more than its outputs and a dynamic block's small lists"
	}
	Fuzz.keep
}

max_texts : U64
max_texts = 8

compress_all : Deflate.Compressor, List(List(U8)) -> List(List(U8))
compress_all = |comp, texts| {
	var $comp = comp
	var $outputs = List.with_capacity(List.len(texts))
	for text in texts {
		done = Deflate.compress_with($comp, text)
		$comp = done.compressor
		$outputs = List.append($outputs, done.output)
	}
	$outputs
}

decompress_all : Deflate.Decoder, List({ stream : List(U8), size : U64 }) -> { decoder : Deflate.Decoder, outputs : List(Try(List(U8), [CorruptData, UnexpectedEnd, OutputLimitExceeded])) }
decompress_all = |dec, streams| {
	var $dec = dec
	var $outputs = List.with_capacity(List.len(streams))
	for { stream, size } in streams {
		done = Deflate.decompress_with($dec, stream, { expected_size: Declared(size) })
		$dec = done.decoder
		$outputs = List.append($outputs, done.output)
	}
	{ decoder: $dec, outputs: $outputs }
}

# The longest input a level stores without compressing (libdeflate's
# `max_passthrough_size`).
passthrough : U64 -> U64
passthrough = |level| if level == 0 {
	U64.highest
} else {
	55 - 4 * level
}

# The fixed-size table lists a level's compressor allocates: the hash table at
# level 1, the two hash-head lists and the chain links at levels 2 to 9, and
# the one list of binary-tree children and hash heads at levels 10 to 12.
fixed_tables : U64 -> U64
fixed_tables = |level|
	if level == 0 {
		0
	} else if level == 1 {
		1
	} else if level <= 9 {
		3
	} else {
		1
	}

# The match-copy scratch a declared size reserves past the output.
output_scratch : U64
output_scratch = 40

# Measured on nightly-2026-11-07-ad3a5d2 over a 2,145-input corpus: at most
# 1,156 bytes a stream beyond its output, the small zeroed lists its dynamic
# blocks take fresh and its slot in the outputs list. One decode table is
# 9,368 bytes, so a warm decoder that rebuilt a table's storage would cross it.
warm_decode_overhead_ceiling : U64
warm_decode_overhead_ceiling = 2_000

text : List(U8)
text = "the cat, the cow, the crow, then the cricket saw the cow again and again".to_utf8()

example : Str, U64, List(List(Plaintext.Piece)) -> Fuzz.Example(Input)
example = |name, level, texts| Fuzz.example({ name, revision: "1", make: || Input.{ texts, level } })

target = Fuzz.target_with!({
	name: "state-reuse",
	examples: [
		example("none", 6, []),
		example("one-stored", 0, [[{ literal: text, back: 0, len: 0 }]]),
		example("mixed-1", 1, [[{ literal: text, back: 30, len: 1_000 }], [{ literal: [1, 2], back: 0, len: 0 }], [{ literal: text, back: 3, len: 900 }]]),
		example("mixed-6", 6, [[{ literal: text, back: 30, len: 1_000 }], [{ literal: [1, 2], back: 0, len: 0 }], [{ literal: text, back: 3, len: 900 }]]),
		example("mixed-12", 12, [[{ literal: text, back: 30, len: 1_000 }], [{ literal: [1, 2], back: 0, len: 0 }], [{ literal: text, back: 3, len: 900 }]]),
	],
	generator: Input.generator_for(Default),
	test!,
	show: |input| Str.inspect(input),
})
