import Inflate
import CompressLazy
import CompressFast
import CompressOptimal

## DEFLATE (RFC 1951) compression and decompression in pure Roc, ported from
## libdeflate.
##
## `decompress` handles all three block types (stored, fixed Huffman, dynamic
## Huffman), so it reads streams produced by zlib, gzip, and ZIP tools.
## `compress` takes a `Level` from 0 to 12 with the same meaning libdeflate
## gives it: the level selects the parser and how hard it searches.

## Errors that can occur when decompressing a DEFLATE stream.
##
## `UnexpectedEnd` means the input ran out before the final block ended, so
## any truncated stream, an empty input included, reports it. `CorruptData`
## means the bytes that are there are not a valid DEFLATE stream.
## `OutputLimitExceeded` means the stream asked for more output than its
## `Bounds` allow, and decoding stopped before writing it.
DeflateError : [
	CorruptData,
	UnexpectedEnd,
	OutputLimitExceeded,
]

Deflate := [].{

	## A compression level from 0 to 12, with libdeflate's meaning: 0 stores the
	## input without compressing it, 1 is the fastest, 6 the usual default, and
	## 12 searches hardest.
	##
	## A number literal is a `Level` wherever one is expected, so
	## `Deflate.compress(bytes, 6)` works, and a literal outside 0 to 12 is a
	## compile-time error. A level only known at runtime, such as one read from
	## a command-line argument, goes through `from_u64`.
	Level :: U8.{
		is_eq : _
		to_hash : _

		## Turn a number literal into a level when the program is compiled,
		## rejecting any literal that is not a whole number from 0 to 12.
		from_numeral : Numeral -> Try(Level, [InvalidNumeral(Str)])
		from_numeral = |numeral|
			match U8.from_numeral(numeral) {
				Ok(n) if n <= 12 => Ok(Level.(n))
				_ => Err(InvalidNumeral("A compression level is a whole number from 0 to 12."))
			}

		## The level for a number only known at runtime.
		from_u64 : U64 -> Try(Level, [OutOfRange])
		from_u64 = |n|
			if n <= 12 {
				Ok(Level.(n.to_u8_wrap()))
			} else {
				Err(OutOfRange)
			}

		## The level's number, from 0 to 12.
		to_u64 : Level -> U64
		to_u64 = |Level.(n)| n.to_u64()

		## Every level, from 0 to 12.
		all : List(Level)
		all = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
	}

	## Compress bytes into a raw DEFLATE stream at the given level.
	##
	## This never fails. It crashes only on a bug in this package.
	compress : List(U8), Level -> List(U8)
	compress = |input, chosen|
		Deflate.compress_into(input, chosen, [])

	## Compress bytes into a raw DEFLATE stream at the given level, appending
	## the stream to `out`.
	##
	## The compressor reserves `compress_bound` bytes past what `out` holds
	## before writing, so passing a list with that much spare capacity means
	## it never reallocates, and a returned list can be emptied with its
	## capacity kept and passed back in for the next stream. Reusing one
	## buffer that way also reuses its memory, which a fresh list for every
	## stream has to fetch from the system again.
	compress_into : List(U8), Level, List(U8) -> List(U8)
	compress_into = |input, chosen, out| {
		level = chosen.to_u64()
		# Level 0 never compresses. Above it, inputs this short are not worth
		# trying to compress, and the higher the level, the shorter an input it
		# still tries on (libdeflate's `max_passthrough_size`).
		max_passthrough = if level == 0 { 18446744073709551615 } else { 55 - 4 * level }
		if List.len(input) <= max_passthrough {
			store_uncompressed(input, out)
		} else if level == 1 {
			CompressFast.compress(input, 32, out)
		} else if level >= 10 {
			CompressOptimal.compress(input, optimal_params_for(level), out)
		} else {
			params = params_for(level)
			if params.lazy == 0 {
				CompressLazy.compress_greedy(input, params, out)
			} else {
				CompressLazy.compress(input, params, out)
			}
		}
	}

	## The largest a compressed stream can be, matching libdeflate's bound.
	##
	## The compressor never uses a compressed block where an uncompressed one
	## would be cheaper, so the worst case is all uncompressed blocks: five
	## bytes of header each, over blocks no shorter than the minimum block
	## length.
	compress_bound : U64 -> U64
	compress_bound = |in_nbytes| {
		max_blocks = ((in_nbytes + CompressLazy.min_block_length - 1) // CompressLazy.min_block_length).max(1)
		5 * max_blocks + in_nbytes
	}

	## Bounds on the bytes one stream appends to its output.
	##
	## DEFLATE expands up to about 1032:1, so a small hostile stream can ask
	## for gigabytes. Decoding stops with `OutputLimitExceeded` before any
	## write that would take the output past `max_output`, so the output never
	## holds more than that. `{}` takes the defaults, and
	## `{ max_output: 65_536 }` names only what differs.
	##
	## `expected_size` is a hint for the output's capacity, such as a ZIP
	## entry's declared uncompressed size. With `Declared(n)`, decoding
	## reserves `n` bytes up front, never more than `max_output`, so a truthful
	## size means the output never reallocates. It is not checked: a longer
	## stream still decodes, growing the output, as long as it stays within
	## `max_output`. A caller that wants the declared size enforced passes it
	## as `max_output` too.
	Bounds := {
		## The most bytes this stream may append, not counting what `out`
		## already holds. The default is 1 GiB.
		max_output : U64 ?? 1_073_741_824,

		## How much output capacity to reserve before decoding.
		expected_size : [Unknown, Declared(U64)] ?? Unknown,
	}

	## Decompress a raw DEFLATE stream, within `bounds`.
	##
	## Without a declared size, the output starts with room for three times
	## the input, never more than `max_output`.
	decompress : List(U8), Bounds -> Try(List(U8), DeflateError)
	decompress = |input, bounds|
		Inflate.inflate(Inflate.new_scratch(), input, [], bounds.max_output, reserve_for(input, bounds)).output

	## Decompress a raw DEFLATE stream, appending the output to `out`, within
	## `bounds`.
	##
	## Passing a list with enough spare capacity for the whole result means
	## the decompressor never reallocates mid-stream, and a returned list can
	## be emptied with its capacity kept and passed back in for the next
	## stream. A `Declared` size reserves that much past what `out` holds.
	##
	## The stream cannot refer back into the bytes `out` already holds. A
	## match that reaches past the start of the stream's own output is
	## `CorruptData`, the same as with an empty `out`.
	decompress_into : List(U8), List(U8), Bounds -> Try(List(U8), DeflateError)
	decompress_into = |input, out, bounds| {
		reserve = match bounds.expected_size {
			Declared(n) => n
			Unknown => 0
		}
		Inflate.inflate(Inflate.new_scratch(), input, out, bounds.max_output, reserve).output
	}

	## The decode tables and scratch space a decompression works in, kept
	## between streams.
	##
	## `decompress` allocates about 12 KB of tables for every stream.
	## Decoding many streams, such as the entries of a ZIP archive, through
	## one `Decoder` allocates them once, as libdeflate's
	## `libdeflate_alloc_decompressor` does. The output is the same as
	## `decompress` gives.
	Decoder :: { scratch : Inflate.Scratch }

	## A decoder for `decompress_with`.
	decoder : () -> Decoder
	decoder = || { scratch: Inflate.new_scratch() }

	## Decompress a raw DEFLATE stream within `bounds`, using the decoder's
	## tables, and hand the decoder back for the next stream.
	##
	## A stream that fails may leave the tables half built, so the decoder
	## handed back after an error has fresh ones.
	decompress_with : Decoder, List(U8), Bounds -> { decoder : Decoder, output : Try(List(U8), DeflateError) }
	decompress_with = |dec, input, bounds| {
		done = Inflate.inflate(dec.scratch, input, [], bounds.max_output, reserve_for(input, bounds))
		{ decoder: { scratch: done.scratch }, output: done.output }
	}
}

# The capacity to reserve for a stream's output: the declared size, or else
# three times the input, which `Inflate.inflate` caps at the bound.
reserve_for : List(U8), Deflate.Bounds -> U64
reserve_for = |input, bounds|
	match bounds.expected_size {
		Declared(n) => n
		Unknown => List.len(input).min(U64.highest // 3) * 3
	}

# Emit the input as stored blocks, which is what the format requires even
# for empty input.
store_uncompressed : List(U8), List(U8) -> List(U8)
store_uncompressed = |input, out| {
	in_end = List.len(input)
	var $out = List.reserve(out, in_end + 5 * (in_end // 65535 + 1))
	if in_end == 0 {
		$out = List.append($out, 1)
		$out = match 0xFFFF0000.U64.append_le_bytes_to($out, 4) {
			Ok(next) => next
			Err(_) => crash "Deflate.store_uncompressed: appended more than 8 bytes"
		}
		$out
	} else {
		var $in_next = 0.U64
		var $storing = 1.U64
		while $storing == 1 {
			remaining = in_end - $in_next
			len = remaining.min(65535)
			bfinal = if remaining <= 65535 { 1.U64 } else { 0 }
			$out = List.append($out, bfinal.to_u8_wrap())
			$out = match len.append_le_bytes_to($out, 2) {
				Ok(next) => next
				Err(_) => crash "Deflate.store_uncompressed: appended more than 8 bytes"
			}
			$out = match len.bitwise_not().append_le_bytes_to($out, 2) {
				Ok(next) => next
				Err(_) => crash "Deflate.store_uncompressed: appended more than 8 bytes"
			}
			$out = List.append_sublist($out, input, { start: $in_next, len })
			$in_next = $in_next + len
			if $in_next == in_end {
				$storing = 0
			} else {
			}
		}
		$out
	}
}

# The search parameters libdeflate uses at each level.
params_for : U64 -> CompressLazy.Params
params_for = |level|
	if level <= 2 {
		{ max_search_depth: 6, nice_match_length: 10, lazy: 0 }
	} else if level == 3 {
		{ max_search_depth: 12, nice_match_length: 14, lazy: 0 }
	} else if level == 4 {
		{ max_search_depth: 16, nice_match_length: 30, lazy: 0 }
	} else if level == 5 {
		{ max_search_depth: 16, nice_match_length: 30, lazy: 1 }
	} else if level == 6 {
		{ max_search_depth: 35, nice_match_length: 65, lazy: 1 }
	} else if level == 7 {
		{ max_search_depth: 100, nice_match_length: 130, lazy: 1 }
	} else if level == 8 {
		{ max_search_depth: 300, nice_match_length: 258, lazy: 2 }
	} else {
		{ max_search_depth: 600, nice_match_length: 258, lazy: 2 }
	}

# The near-optimal parser's parameters at each of the levels that use it.
#
# As well as searching harder, the higher levels spend more optimization
# passes on each block, keep going for smaller improvements, and are
# willing to optimize the static-Huffman alternative for longer blocks.
optimal_params_for : U64 -> CompressOptimal.Params
optimal_params_for = |level|
	if level == 10 {
		{
			max_search_depth: 35,
			nice_match_length: 75,
			max_optim_passes: 2,
			min_improvement_to_continue: 32,
			min_bits_to_use_nonfinal_path: 32,
			max_len_to_optimize_static_block: 0,
		}
	} else if level == 11 {
		{
			max_search_depth: 100,
			nice_match_length: 150,
			max_optim_passes: 4,
			min_improvement_to_continue: 16,
			min_bits_to_use_nonfinal_path: 16,
			max_len_to_optimize_static_block: 1000,
		}
	} else {
		{
			max_search_depth: 300,
			nice_match_length: 258,
			max_optim_passes: 10,
			min_improvement_to_continue: 1,
			min_bits_to_use_nonfinal_path: 1,
			max_len_to_optimize_static_block: 10000,
		}
	}

# The tests here are the fast ones, so `roc test` stays quick on every
# backend, the interpreter included. Hand-built streams pin the decoder to the
# format itself rather than to this package's compressor. tests/harness.roc
# covers the large inputs, byte-identity with libdeflate at every level, and
# the decoder's error cases in bulk.

# A final fixed Huffman block holding only the end-of-block code.
expect Deflate.decompress([0x03, 0x00], {}) == Ok([])

# A final stored block of "Hello": LEN 5, then NLEN, its complement.
expect Deflate.decompress([0x01, 0x05, 0x00, 0xFA, 0xFF, 0x48, 0x65, 0x6C, 0x6C, 0x6F], {}) == Ok("Hello".to_utf8())

# The same block with an NLEN that is not LEN's complement.
expect Deflate.decompress([0x01, 0x05, 0x00, 0xFB, 0xFF, 0x48, 0x65, 0x6C, 0x6C, 0x6F], {}) == Err(CorruptData)

# BTYPE 3 is reserved.
expect Deflate.decompress([0x07], {}) == Err(CorruptData)

# Input that ends before the stream does, the empty input included, wherever
# it stops: in a block header, in a stored block's payload, or in a dynamic
# block's code lengths.
expect Deflate.decompress([], {}) == Err(UnexpectedEnd)

expect Deflate.decompress([0x03], {}) == Err(UnexpectedEnd)

expect Deflate.decompress([0x01, 0x05, 0x00, 0xFA, 0xFF, 0x48, 0x65], {}) == Err(UnexpectedEnd)

expect {
	stream = Deflate.compress("abcdefghijklmnopqrstuvwxyz, abcdefghijklmnopqrstuvwxyz, and the alphabet again".to_utf8(), 6)
	Deflate.decompress(List.sublist(stream, { start: 0, len: 3 }), {}) == Err(UnexpectedEnd)
}

# A fixed block holding one match, length 3 at distance 3, with no output
# before it to copy from.
expect Deflate.decompress([0x03, 0x22, 0x00], {}) == Err(CorruptData)

# The bytes `out` already holds are not part of the stream, so the match is
# just as corrupt when there is something there to copy.
expect Deflate.decompress_into([0x03, 0x22, 0x00], [1, 2, 3], {}) == Err(CorruptData)

# The output is appended to what `out` holds.
expect Deflate.decompress_into([0x01, 0x05, 0x00, 0xFA, 0xFF, 0x48, 0x65, 0x6C, 0x6C, 0x6F], [1, 2], {}) == Ok([1, 2, 0x48, 0x65, 0x6C, 0x6C, 0x6F])

# A stored block is checked against the bound before its copy: five bytes fit
# a bound of five and not one of four, counting from what `out` holds.
expect Deflate.decompress([0x01, 0x05, 0x00, 0xFA, 0xFF, 0x48, 0x65, 0x6C, 0x6C, 0x6F], { max_output: 5 }) == Ok("Hello".to_utf8())

expect Deflate.decompress([0x01, 0x05, 0x00, 0xFA, 0xFF, 0x48, 0x65, 0x6C, 0x6C, 0x6F], { max_output: 4 }) == Err(OutputLimitExceeded)

expect Deflate.decompress_into([0x01, 0x05, 0x00, 0xFA, 0xFF, 0x48, 0x65, 0x6C, 0x6C, 0x6F], [1, 2], { max_output: 5 }) == Ok([1, 2, 0x48, 0x65, 0x6C, 0x6C, 0x6F])

# A truncated stream is still truncated under a bound it would pass.
expect Deflate.decompress([0x01, 0x05, 0x00, 0xFA, 0xFF, 0x48, 0x65], { max_output: 1 }) == Err(UnexpectedEnd)

# Huffman blocks give exactly their output at a bound of its length and stop
# one byte short of it, through both the fast loop and the careful loop:
# short inputs only reach the careful loop, the long run mostly the fast one,
# and the bound lands anywhere in a match or a run of literals.
expect {
	text = "the cat, the cow, the crow, then the cricket saw the cow again and again".to_utf8()
	inputs = [text, List.join(List.repeat(text, 200)), List.repeat(0.U8, 100_000)]
	var $ok = True
	for input in inputs {
		len = List.len(input)
		for level in [1, 6, 12] {
			compressed = Deflate.compress(input, level)
			for max_output in [len, len + 1, len - 1, len // 2, len - len.min(300), 0] {
				expected = if len <= max_output {
					Ok(input)
				} else {
					Err(OutputLimitExceeded)
				}
				if Deflate.decompress(compressed, { max_output: max_output }) != expected {
					$ok = False
				} else {}
				if Deflate.decompress(compressed, { max_output: max_output, expected_size: Declared(len) }) != expected {
					$ok = False
				} else {}
			}
		}
	}
	$ok
}

# A declared size is a hint, not a check: a stream longer or shorter than it
# still decodes, and a size far above the bound reserves no more than the
# bound.
expect {
	input = List.repeat(7.U8, 5000)
	compressed = Deflate.compress(input, 6)
	Deflate.decompress(compressed, { expected_size: Declared(10) }) == Ok(input)
		and Deflate.decompress(compressed, { expected_size: Declared(1_000_000) }) == Ok(input)
		and Deflate.decompress(compressed, { max_output: 4999, expected_size: Declared(U64.highest) }) == Err(OutputLimitExceeded)
}

# One decoder gives the same output as `decompress` stream after stream,
# whatever block types follow each other, and after a failed stream too.
expect {
	text = "the cat, the cow, the crow, then the cricket saw the cow again and again".to_utf8()
	long = List.join(List.repeat(text, 50))
	streams = [
		Deflate.compress(long, 6),
		Deflate.compress(text, 1),
		[0x03, 0x22, 0x00],
		Deflate.compress(long, 12),
		[0x01, 0x05, 0x00, 0xFA, 0xFF, 0x48, 0x65, 0x6C, 0x6C, 0x6F],
		Deflate.compress(text, 0),
		Deflate.compress(long, 9),
		Deflate.compress(long, 4),
	]
	all_bounds : List(Deflate.Bounds)
	all_bounds = [{}, { max_output: 100 }]
	var $dec = Deflate.decoder()
	var $ok = True
	for stream in streams {
		for bounds in all_bounds {
			done = Deflate.decompress_with($dec, stream, bounds)
			if done.output != Deflate.decompress(stream, bounds) {
				$ok = False
			} else {}
			$dec = done.decoder
		}
	}
	$ok
}

# Every level round-trips the shortest inputs and the two lengths either side
# of its passthrough limit, the longest input it stores without trying to
# compress, and stays within `compress_bound`.
expect {
	text = "the cat, the cow, the crow, then the cricket saw the cow again and again".to_utf8()
	var $ok = True
	for level in Deflate.Level.all {
		n = level.to_u64()
		limit = if n == 0 { 64 } else { 55 - 4 * n }
		for len in [0, 1, 2, 3, 4, 5, limit, limit + 1] {
			original = List.sublist(text, { start: 0, len })
			compressed = Deflate.compress(original, level)
			if Deflate.decompress(compressed, {}) != Ok(original) or List.len(compressed) > Deflate.compress_bound(len) {
				$ok = False
			} else {}
		}
	}
	$ok
}

# Bytes that do not compress at all are where `compress_bound` is tightest.
expect {
	noise = List.repeat(0.U8, 3000).map_with_index(|_, i| {
		a = i.times_wrap(0x9E3779B97F4A7C15)
		b = a.bitwise_xor(a.shr_zf_wrap(29)).times_wrap(0xBF58476D1CE4E5B9)
		b.bitwise_xor(b.shr_zf_wrap(32)).shr_zf_wrap(56).to_u8_wrap()
	})
	var $ok = True
	for level in Deflate.Level.all {
		compressed = Deflate.compress(noise, level)
		if Deflate.decompress(compressed, {}) != Ok(noise) or List.len(compressed) > Deflate.compress_bound(3000) {
			$ok = False
		} else {}
	}
	$ok
}

# `compress_into` appends to what `out` holds, and the stream it appends is
# the one `compress` returns, at every level, whether or not `out` already
# has spare capacity.
expect {
	text = "the cat, the cow, the crow, then the cricket saw the cow again and again".to_utf8()
	var $ok = True
	for level in Deflate.Level.all {
		alone = Deflate.compress(text, level)
		appended = Deflate.compress_into(text, level, [7, 8])
		reused = Deflate.compress_into(text, level, List.with_capacity(Deflate.compress_bound(List.len(text))))
		if appended != List.concat([7, 8], alone) or reused != alone {
			$ok = False
		} else {}
	}
	$ok
}

# A level from a runtime number is checked there, and every level is listed
# once, in order.
expect Deflate.Level.from_u64(12).map_ok(|level| level.to_u64()) == Ok(12)

expect Deflate.Level.from_u64(13).is_err()

expect Deflate.Level.all.map(|level| level.to_u64()) == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
