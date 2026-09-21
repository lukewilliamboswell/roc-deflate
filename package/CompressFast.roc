import DeflateTables
import HuffmanEncode
import BlockOut
import Matchfinder
import HtMatchfinder
import CompressLazy

## The fastest DEFLATE parser, ported from libdeflate's
## `deflate_compress_fastest`.
##
## This is the greedy parser with two things given up for speed: the
## hash-table matchfinder replaces the hash chains, so the work per position is
## fixed rather than bounded by a search depth, and blocks end at a fixed
## length instead of where the block splitter would put them.
CompressFast := [].{

	## Blocks end here rather than where a split would be worthwhile, so this
	## sits below the block length the other parsers aim for.
	fast_soft_max_block_length : U64
	fast_soft_max_block_length = 65535

	fast_seq_store_length : U64
	fast_seq_store_length = 8192

	compress : List(U8), U64 -> Try(List(U8), [CompressBug])
	compress = |input, nice_match_length| {
		in_end = List.len(input)
		static = CompressLazy.build_static_codes(0)?
		var $s_litlen_lens = static.litlen_lens
		var $s_litlen_codewords = static.litlen_codewords
		var $s_offset_lens = static.offset_lens
		var $s_offset_codewords = static.offset_codewords

		var $out = List.with_capacity(5 * ((in_end + CompressLazy.min_block_length - 1) // CompressLazy.min_block_length).max(1) + in_end)
		var $bitbuf = 0.U64
		var $bitcount = 0.U64
		var $in_next = 0.U64
		var $max_len = DeflateTables.max_match_len
		var $nice_len = nice_match_length.min(DeflateTables.max_match_len)
		# Held apart rather than in one record: see HtMatchfinder.State.
		var $tab = Matchfinder.init_nodes(HtMatchfinder.table_size)
		var $base = 0.U64
		var $nh = 0.U64
		# One allocation for the whole stream: a block appends its sequences and
		# the run terminator, and clearing the list afterwards keeps the capacity.
		var $seqs = List.with_capacity(CompressFast.fast_seq_store_length + 1)

		var $blocking = 1.U64
		while $blocking == 1 {
			in_block_begin = $in_next
			in_max_block_end = CompressLazy.choose_max_block_end(
				$in_next,
				in_end,
				CompressFast.fast_soft_max_block_length,
			)
			var $freqs_litlen = List.repeat(0.U32, DeflateTables.num_litlen_syms)
			var $freqs_offset = List.repeat(0.U32, DeflateTables.num_offset_syms)
			$seqs = List.clear($seqs)
			var $litrunlen = 0.U32

			# Wrapping arithmetic on the per-position path: the cursor never passes
			# the input end, a match is at least three bytes, and every run length
			# and symbol count stays below the block length, so a checked add or
			# subtract here would only put an overflow branch on every position.
			var $in_block = 1.U64
			while $in_block == 1 {
				remaining = in_end.minus_wrap($in_next)
				var $searched = 1.U64
				if remaining < DeflateTables.max_match_len {
					$max_len = remaining
					if $max_len < HtMatchfinder.required_nbytes {
						# Too little left to hash; the rest are literals.
						var $left = $max_len
						while $left > 0 {
							lit = (List.get(input, $in_next) ?? 0).to_u64()
							lit_count = (List.get($freqs_litlen, lit) ?? 0).plus_wrap(1)
							$freqs_litlen = match List.set($freqs_litlen, lit, lit_count) {
								Ok(next) => next
								Err(_) => return Err(CompressBug)
							}
							$litrunlen = $litrunlen.plus_wrap(1)
							$in_next = $in_next.plus_wrap(1)
							$left = $left.minus_wrap(1)
						}
						$searched = 0
						$in_block = 0
					} else {
						$nice_len = $nice_len.min($max_len)
					}
				} else {
				}

				if $searched == 1 {
					found = HtMatchfinder.longest_match($tab, $base, $nh, input, $in_next, $max_len, $nice_len)?
					$tab = found.hash_tab
					$base = found.in_cur_base
					$nh = found.next_hash

					if found.length != 0 {
						length_slot = DeflateTables.length_slot(found.length)
						offset_slot = DeflateTables.offset_slot(found.offset)
						litlen_sym = DeflateTables.first_len_sym.plus_wrap(length_slot)
						litlen_sym_count = (List.get($freqs_litlen, litlen_sym) ?? 0).plus_wrap(1)
						$freqs_litlen = match List.set($freqs_litlen, litlen_sym, litlen_sym_count) {
							Ok(next) => next
							Err(_) => return Err(CompressBug)
						}
						offset_slot_count = (List.get($freqs_offset, offset_slot) ?? 0).plus_wrap(1)
						$freqs_offset = match List.set($freqs_offset, offset_slot, offset_slot_count) {
							Ok(next) => next
							Err(_) => return Err(CompressBug)
						}
						$seqs = List.append($seqs, {
							litrunlen_and_length: $litrunlen.bitwise_or(found.length.to_u32_wrap().shl_wrap(BlockOut.seq_length_shift)),
							offset: found.offset.to_u16_wrap(),
							offset_slot: offset_slot.to_u16_wrap(),
						})
						$litrunlen = 0

						skipped = HtMatchfinder.skip_bytes($tab, $base, $nh, input, $in_next.plus_wrap(1), in_end, found.length.minus_wrap(1))?
						$tab = skipped.hash_tab
						$base = skipped.in_cur_base
						$nh = skipped.next_hash
						$in_next = $in_next.plus_wrap(found.length)
					} else {
						lit = (List.get(input, $in_next) ?? 0).to_u64()
						lit_count = (List.get($freqs_litlen, lit) ?? 0).plus_wrap(1)
						$freqs_litlen = match List.set($freqs_litlen, lit, lit_count) {
							Ok(next) => next
							Err(_) => return Err(CompressBug)
						}
						$litrunlen = $litrunlen.plus_wrap(1)
						$in_next = $in_next.plus_wrap(1)
					}

					if $in_next >= in_max_block_end or List.len($seqs) >= CompressFast.fast_seq_store_length {
						$in_block = 0
					} else {
					}
				} else {
				}
			}

			$seqs = List.append($seqs, {
				litrunlen_and_length: $litrunlen,
				offset: 0.U16,
				offset_slot: 0.U16,
			})
			$freqs_litlen = match List.set($freqs_litlen, DeflateTables.end_of_block,
				(List.get($freqs_litlen, DeflateTables.end_of_block) ?? 0) + 1) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			litlen_code = HuffmanEncode.make_code(
				DeflateTables.num_litlen_syms,
				BlockOut.max_litlen_codeword_len,
				$freqs_litlen,
				List.repeat(0.U8, DeflateTables.num_litlen_syms),
				List.repeat(0.U32, DeflateTables.num_litlen_syms),
			)?
			offset_code = HuffmanEncode.make_code(
				DeflateTables.num_offset_syms,
				BlockOut.max_offset_codeword_len,
				$freqs_offset,
				List.repeat(0.U8, DeflateTables.num_offset_syms),
				List.repeat(0.U32, DeflateTables.num_offset_syms),
			)?

			is_final = if $in_next == in_end { 1 } else { 0 }
			flushed = BlockOut.flush_block(
				$out,
				$bitbuf,
				$bitcount,
				input,
				in_block_begin,
				$in_next - in_block_begin,
				$seqs,
				$freqs_litlen,
				$freqs_offset,
				litlen_code.lens,
				litlen_code.codewords,
				offset_code.lens,
				offset_code.codewords,
				$s_litlen_lens,
				$s_litlen_codewords,
				$s_offset_lens,
				$s_offset_codewords,
				[],
				0,
				is_final,
			)?
			$out = flushed.out
			$bitbuf = flushed.bitbuf
			$bitcount = flushed.bitcount
			$seqs = flushed.seqs
			$s_litlen_lens = flushed.static_litlen_lens
			$s_litlen_codewords = flushed.static_litlen_codewords
			$s_offset_lens = flushed.static_offset_lens
			$s_offset_codewords = flushed.static_offset_codewords

			if $in_next == in_end {
				$blocking = 0
			} else {
			}
		}

		if $bitcount > 0 {
			$out = List.append($out, $bitbuf.to_u8_wrap())
		} else {
		}
		Ok($out)
	}
}
