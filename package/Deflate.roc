import Inflate
import CompressLazy
import CompressFast
import CompressOptimal

## DEFLATE (RFC 1951) compression and decompression in pure Roc, ported from
## libdeflate.
##
## `decompress` handles all three block types (stored, fixed Huffman, dynamic
## Huffman), so it reads streams produced by zlib, gzip, and ZIP tools.
## `compress` takes a level from 1 to 12 with the same meaning libdeflate gives
## it: the level selects the parser and how hard it searches.

## Errors that can occur when decompressing a DEFLATE stream.
DeflateError : [
	CorruptData,
	UnexpectedEnd,
]

Deflate := [].{

	## Compress bytes into a raw DEFLATE stream at the given level, 1 to 12.
	compress : List(U8), U64 -> Try(List(U8), [CompressBug])
	compress = |input, level| {
		# Inputs this short are not worth trying to compress; the higher the
		# level, the more it is worth bothering.
		# Level 0 never compresses; above it, the higher the level the more
		# it is worth bothering with a very short input.
		max_passthrough = if level == 0 {
			18446744073709551615
		} else if level * 4 >= 55 {
			0
		} else {
			55 - level * 4
		}
		if List.len(input) <= max_passthrough {
			Deflate.store_uncompressed(input)
		} else if level == 1 {
			CompressFast.compress(input, 32)
		} else if level >= 10 {
			CompressOptimal.compress(input, Deflate.optimal_params_for(level))
		} else {
			params = Deflate.params_for(level)
			if params.lazy == 0 {
				CompressLazy.compress_greedy(input, params)
			} else {
				CompressLazy.compress(input, params)
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

	## Emit the input as stored blocks, which is what the format requires even
	## for empty input.
	store_uncompressed : List(U8) -> Try(List(U8), [CompressBug])
	store_uncompressed = |input| {
		in_end = List.len(input)
		var $out = List.with_capacity(in_end + 5 * (in_end // 65535 + 1))
		if in_end == 0 {
			$out = List.append($out, 1)
			$out = match (0xFFFF0000.U64).append_le_bytes_to($out, 4) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			Ok($out)
		} else {
			var $in_next = 0.U64
			var $storing = 1.U64
			while $storing == 1 {
				remaining = in_end - $in_next
				len = remaining.min(65535)
				bfinal = if remaining <= 65535 {
					1.U64
				} else {
					0
				}
				$out = List.append($out, bfinal.to_u8_wrap())
				$out = match len.append_le_bytes_to($out, 2) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				$out = match len.bitwise_not().append_le_bytes_to($out, 2) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				$out = List.append_sublist($out, input, { start: $in_next, len })
				$in_next = $in_next + len
				if $in_next == in_end {
					$storing = 0
				} else {}
			}
			Ok($out)
		}
	}

	## The search parameters libdeflate uses at each level.
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

	## The near-optimal parser's parameters at each of the levels that use it.
	##
	## As well as searching harder, the higher levels spend more optimization
	## passes on each block, keep going for smaller improvements, and are
	## willing to optimize the static-Huffman alternative for longer blocks.
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

	## Decompress a raw DEFLATE stream.
	decompress : List(U8) -> Try(List(U8), DeflateError)
	decompress = |input|
		Inflate.decompress(input)

	## Decompress a raw DEFLATE stream, appending the output to `out`.
	##
	## Passing a list with enough spare capacity for the whole result means
	## the decompressor never reallocates mid-stream, and a returned list can
	## be emptied with its capacity kept and passed back in for the next
	## stream.
	decompress_into : List(U8), List(U8) -> Try(List(U8), DeflateError)
	decompress_into = |input, out|
		Inflate.decompress_into(input, out)
}
