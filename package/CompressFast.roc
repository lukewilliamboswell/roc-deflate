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

	## The hash-table matchfinder's table and the sequence store, which a
	## `Deflate.Compressor` keeps between streams. Empty lists are fresh
	## tables: every stream starts from a cleared table either way.
	FastTables : { tab : List(U16), seqs : List(BlockOut.Sequence) }

	## No tables yet, for a single stream.
	no_fast_tables : FastTables
	no_fast_tables = { tab: [], seqs: [] }

	compress : List(U8), U64, List(U8) -> List(U8)
	compress = |input, nice_match_length, out|
		CompressFast.compress_with(input, nice_match_length, out, CompressFast.no_fast_tables).out

	## `compress` in the table and store a previous stream left, handing them
	## back with the stream.
	compress_with : List(U8), U64, List(U8), FastTables -> { out : List(U8), tab : List(U16), seqs : List(BlockOut.Sequence) }
	compress_with = |input, nice_match_length, out, tables| {
		tab_0 = tables.tab
		seqs_0 = tables.seqs
		in_end = List.len(input)
		# Positions before this one have a full-length match in reach, so the
		# search there needs no shortening.
		full_search_end = if in_end >= DeflateTables.max_match_len { in_end - (DeflateTables.max_match_len - 1) } else { 0 }
		static = CompressLazy.build_static_codes(0)
		var $s_litlen_lens = static.litlen_lens
		var $s_litlen_codewords = static.litlen_codewords
		var $s_offset_lens = static.offset_lens
		var $s_offset_codewords = static.offset_codewords

		# The stream is appended to what `out` holds, after reserving the most
		# it can take, so a reused buffer never grows mid-stream.
		var $out = List.reserve(out, 5 * ((in_end + CompressLazy.min_block_length - 1) // CompressLazy.min_block_length).max(1) + in_end)
		var $bitbuf = 0.U64
		var $bitcount = 0.U64
		var $in_next = 0.U64
		var $max_len = DeflateTables.max_match_len
		var $nice_len = nice_match_length.min(DeflateTables.max_match_len)
		# Held apart rather than in one record: see HtMatchfinder.State.
		var $tab = Matchfinder.reset_nodes(tab_0, HtMatchfinder.table_size)
		var $base = 0.U64
		var $nh = 0.U64
		# One allocation for the whole stream: a block appends its sequences and
		# the run terminator, and clearing the list afterwards keeps the capacity.
		# Every match is at least three bytes, so a short input needs only a
		# short store.
		var $seqs = List.reserve(List.clear(seqs_0), (in_end // DeflateTables.min_match_len).min(CompressFast.fast_seq_store_length) + 1)

		var $blocking = 1.U64
		while $blocking == 1 {
			in_block_begin = $in_next
			in_max_block_end = CompressLazy.choose_max_block_end(
				$in_next,
				in_end,
				CompressFast.fast_soft_max_block_length,
			)
			# Each list covers every index its slot lookup can produce, not just
			# the alphabet: the length slot is a byte added to 257 and the offset
			# slot is a byte plus 14, so the counts below need no bounds tests.
			var $freqs_litlen = List.repeat(0.U32, DeflateTables.first_len_sym + 256)
			var $freqs_offset = List.repeat(0.U32, 256 + 14)
			$seqs = List.clear($seqs)
			# The literal run is measured from where it started rather than
			# counted: a match reads it off the cursor, so a literal updates
			# nothing but the cursor.
			var $run_start = $in_next

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
						# Too little left to hash, so the rest are literals.
						var $left = $max_len
						while $left > 0 {
							lit = (List.get(input, $in_next) ?? 0).to_u64()
							lit_count = (List.get($freqs_litlen, lit) ?? 0).plus_wrap(1)
							$freqs_litlen = match List.set($freqs_litlen, lit, lit_count) {
								Ok(next) => next
								Err(_) => crash "CompressFast.compress: freqs_litlen index out of bounds"
							}
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
					# Slide the table when the window has moved one whole window past
					# the base.
					if $in_next.minus_wrap($base) == Matchfinder.window_size {
						$tab = Matchfinder.rebase_nodes($tab)
						$base = $base.plus_wrap(Matchfinder.window_size)
					} else {
					}
					# Literals are scanned in an inner loop that runs until a match is
					# found or the cursor reaches the next position needing one of the
					# outer loop's checks: the window slide, the shortened search near
					# the input end, or the block end. One compare stands in for all
					# three. The scan's end is at least four bytes before the input's,
					# which stated here makes every read at and just past the cursor
					# in bounds.
					scan_end = in_max_block_end.min($base.plus_wrap(Matchfinder.window_size)).min(full_search_end)
					if scan_end + 4 > List.len(input) or List.len($tab) < HtMatchfinder.table_size {
						crash "CompressFast.compress: scan past the input or hash table too short"
					} else {
					}
					# The scan only probes the position's bucket and stops at the first
					# candidate whose four bytes agree, leaving the match extension to
					# run once below. That keeps nothing but the cursor, the hash, and
					# the tables live on the per-literal path: on a 16-register machine
					# one more value there spills the cursor to the stack, putting a
					# store and reload on every literal's critical path.
					scan_start = $in_next
					var $found_node0 = 0.U16
					var $found_node1 = 0.U16
					var $found0 = False
					var $found = False
					while $in_next < scan_end and !$found {
						cur_pos = $in_next.minus_wrap($base)
						seq = U32.from_le_bytes(input, $in_next) ?? 0
						slot0 = $nh.bitwise_and(0x7FFF).times_wrap(2)
						$nh = Matchfinder.lz_hash(U32.from_le_bytes(input, $in_next.plus_wrap(1)) ?? 0, HtMatchfinder.hash_order)
						$tab = List.prefetched($tab, $nh.times_wrap(2))
						cur_node0 = List.get($tab, slot0) ?? 0
						cur_node1 = List.get($tab, slot0.plus_wrap(1)) ?? 0
						$tab = match List.set($tab, slot0, cur_pos.plus_wrap(Matchfinder.node_bias).to_u16_wrap()) {
							Ok(next) => next
							Err(_) => crash "CompressFast.compress: tab index out of bounds"
						}
						# Read both entries before updating this bucket. Even an expired
						# first entry can replace the second: the second is older, so it
						# cannot be a valid candidate when the first has expired.
						$tab = match List.set($tab, slot0.plus_wrap(1), cur_node0) {
							Ok(next) => next
							Err(_) => crash "CompressFast.compress: tab index out of bounds"
						}
						if cur_node0.to_u64() > cur_pos {
							if (U32.from_le_bytes(input, Matchfinder.node_index($base, cur_node0)) ?? 0) == seq {
								$found0 = True
								$found = True
							} else if cur_node1.to_u64() > cur_pos
								and (U32.from_le_bytes(input, Matchfinder.node_index($base, cur_node1)) ?? 0) == seq {
								$found = True
							} else {
							}
							$found_node0 = cur_node0
							$found_node1 = cur_node1
						} else {
						}
						if !$found {
							lit = (List.get(input, $in_next) ?? 0).to_u64()
							lit_count = (List.get($freqs_litlen, lit) ?? 0).plus_wrap(1)
							$freqs_litlen = match List.set($freqs_litlen, lit, lit_count) {
								Ok(next) => next
								Err(_) => crash "CompressFast.compress: freqs_litlen index out of bounds"
							}
							$in_next = $in_next.plus_wrap(1)
						} else {
						}
					}

					var $found_len = 0.U64
					var $found_offset = 0.U64
					if $found {
						# The longest match among the bucket's candidates, as
						# `HtMatchfinder.longest_match` finds it: the first entry if its
						# four bytes agree, then the second if it can be longer.
						cur_pos = $in_next.minus_wrap($base)
						seq = U32.from_le_bytes(input, $in_next) ?? 0
						if $found0 {
							match0_at = Matchfinder.node_index($base, $found_node0)
							$found_len = Matchfinder.lz_extend(input, $in_next, match0_at, 4, $max_len)
							$found_offset = $in_next.minus_wrap(match0_at)
							if $found_node1.to_u64() <= cur_pos or $found_len >= $nice_len {
							} else {
								match1_at = Matchfinder.node_index($base, $found_node1)
								if (U32.from_le_bytes(input, match1_at) ?? 0) == seq
									and (U32.from_le_bytes(input, match1_at.plus_wrap($found_len).minus_wrap(3)) ?? 0)
										== (U32.from_le_bytes(input, $in_next.plus_wrap($found_len).minus_wrap(3)) ?? 0) {
									len = Matchfinder.lz_extend(input, $in_next, match1_at, 4, $max_len)
									if len > $found_len {
										$found_len = len
										$found_offset = $in_next.minus_wrap(match1_at)
									} else {
									}
								} else {
								}
							}
						} else {
							match1_at = Matchfinder.node_index($base, $found_node1)
							$found_len = Matchfinder.lz_extend(input, $in_next, match1_at, 4, $max_len)
							$found_offset = $in_next.minus_wrap(match1_at)
						}
					} else if $in_next == scan_start {
						# A position the scan does not cover, near the input's end or
						# where a slide is due: search it with the general routine. A
						# scan that ran to its end leaves its next position to the
						# outer loop, which shortens the search there if it must.
						found = HtMatchfinder.longest_match($tab, $base, $nh, input, $in_next, $max_len, $nice_len)
						$tab = found.hash_tab
						$base = found.in_cur_base
						$nh = found.next_hash
						if found.length != 0 {
							$found_len = found.length
							$found_offset = found.offset
						} else {
							lit = (List.get(input, $in_next) ?? 0).to_u64()
							lit_count = (List.get($freqs_litlen, lit) ?? 0).plus_wrap(1)
							$freqs_litlen = match List.set($freqs_litlen, lit, lit_count) {
								Ok(next) => next
								Err(_) => crash "CompressFast.compress: freqs_litlen index out of bounds"
							}
							$in_next = $in_next.plus_wrap(1)
						}
					} else {
					}

					if $found_len != 0 {
						length_slot = DeflateTables.length_slot($found_len)
						offset_slot = DeflateTables.offset_slot($found_offset)
						litlen_sym = DeflateTables.first_len_sym.plus_wrap(length_slot)
						litlen_sym_count = (List.get($freqs_litlen, litlen_sym) ?? 0).plus_wrap(1)
						$freqs_litlen = match List.set($freqs_litlen, litlen_sym, litlen_sym_count) {
							Ok(next) => next
							Err(_) => crash "CompressFast.compress: freqs_litlen index out of bounds"
						}
						offset_slot_count = (List.get($freqs_offset, offset_slot) ?? 0).plus_wrap(1)
						$freqs_offset = match List.set($freqs_offset, offset_slot, offset_slot_count) {
							Ok(next) => next
							Err(_) => crash "CompressFast.compress: freqs_offset index out of bounds"
						}
						$seqs = List.append($seqs, {
							litrunlen_and_length: $in_next.minus_wrap($run_start).to_u32_wrap().bitwise_or($found_len.to_u32_wrap().shl_wrap(BlockOut.seq_length_shift)),
							offset: $found_offset.to_u16_wrap(),
							offset_slot: offset_slot.to_u16_wrap(),
						})

						# Insert the positions the match covers. A run that crosses a
						# window slide or reaches the input's last bytes takes the general
						# routine. Every other run is inserted here, where the table and
						# hash are already at hand.
						skip_end = $in_next.plus_wrap($found_len)
						if in_end < 9
							or in_end > List.len(input)
							or skip_end.plus_wrap(HtMatchfinder.required_nbytes) > in_end
							or skip_end.minus_wrap(1).minus_wrap($base) >= Matchfinder.window_size
							or List.len($tab) < HtMatchfinder.table_size {
							skipped = HtMatchfinder.skip_bytes($tab, $base, $nh, input, $in_next.plus_wrap(1), in_end, $found_len.minus_wrap(1))
							$tab = skipped.hash_tab
							$base = skipped.in_cur_base
							$nh = skipped.next_hash
						} else {
							# The run ends at least five bytes before the input does. Taking
							# the smaller of the two as the limit states that where the hash
							# read below can use it.
							skip_limit = skip_end.min(in_end - HtMatchfinder.required_nbytes)
							var $skip_at = $in_next.plus_wrap(1)
							# The node is carried already biased.
							var $skip_node = $skip_at.minus_wrap($base).plus_wrap(Matchfinder.node_bias)
							# An offset-one match is a run of one byte. Every four-byte
							# sequence wholly within it has the same hash, and a bucket
							# retains only its two newest positions. Install those two
							# positions directly, then insert the three sequences that
							# overlap the end of the run normally.
							if $found_offset == 1 and $found_len >= 8 {
								uniform_end = skip_end.minus_wrap(3)
								latest = uniform_end.minus_wrap(1).minus_wrap($base).plus_wrap(Matchfinder.node_bias)
								slot0 = $nh.bitwise_and(32767).times_wrap(2)
								$tab = match List.set($tab, slot0, latest.to_u16_wrap()) {
									Ok(next) => next
									Err(_) => crash "CompressFast.compress: uniform bucket index out of bounds"
								}
								$tab = match List.set($tab, slot0.plus_wrap(1), latest.minus_wrap(1).to_u16_wrap()) {
									Ok(next) => next
									Err(_) => crash "CompressFast.compress: uniform bucket index out of bounds"
								}
								$skip_at = uniform_end
								$skip_node = uniform_end.minus_wrap($base).plus_wrap(Matchfinder.node_bias)
								$nh = Matchfinder.lz_hash(U32.from_le_bytes(input, uniform_end) ?? 0, HtMatchfinder.hash_order)
							} else {
							}
							while $skip_at < skip_limit {
								slot0 = $nh.bitwise_and(0x7FFF).times_wrap(2)
								first = List.get($tab, slot0) ?? 0
								$tab = match List.set($tab, slot0.plus_wrap(1), first) {
									Ok(next) => next
									Err(_) => crash "CompressFast.compress: tab index out of bounds"
								}
								$tab = match List.set($tab, slot0, $skip_node.to_u16_wrap()) {
									Ok(next) => next
									Err(_) => crash "CompressFast.compress: tab index out of bounds"
								}
								$skip_at = $skip_at.plus_wrap(1)
								$skip_node = $skip_node.plus_wrap(1)
								$nh = Matchfinder.lz_hash(U32.from_le_bytes(input, $skip_at) ?? 0, HtMatchfinder.hash_order)
							}
							$tab = List.prefetched($tab, $nh.times_wrap(2))
						}
						$in_next = skip_end
						$run_start = $in_next
					} else {
					}

					if $in_next >= in_max_block_end or List.len($seqs) >= CompressFast.fast_seq_store_length {
						$in_block = 0
					} else {
					}
				} else {
				}
			}

			$seqs = List.append($seqs, {
				litrunlen_and_length: $in_next.minus_wrap($run_start).to_u32_wrap(),
				offset: 0.U16,
				offset_slot: 0.U16,
			})
			$freqs_litlen = match List.set($freqs_litlen, DeflateTables.end_of_block,
				(List.get($freqs_litlen, DeflateTables.end_of_block) ?? 0) + 1) {
				Ok(next) => next
				Err(_) => crash "CompressFast.compress: freqs_litlen index out of bounds"
			}
			litlen_code = HuffmanEncode.make_code(
				DeflateTables.num_litlen_syms,
				BlockOut.max_litlen_codeword_len,
				$freqs_litlen,
				List.repeat(0.U8, DeflateTables.num_litlen_syms),
				List.repeat(0.U32, DeflateTables.num_litlen_syms),
			)
			offset_code = HuffmanEncode.make_code(
				DeflateTables.num_offset_syms,
				BlockOut.max_offset_codeword_len,
				$freqs_offset,
				List.repeat(0.U8, DeflateTables.num_offset_syms),
				List.repeat(0.U32, DeflateTables.num_offset_syms),
			)

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
			)
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
		{ out: $out, tab: $tab, seqs: $seqs }
	}
}
