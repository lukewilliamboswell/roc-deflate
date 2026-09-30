import DeflateTables
import HuffmanEncode
import BlockOut
import Matchfinder
import HcMatchfinder

## The greedy and lazy DEFLATE parsers, ported from libdeflate's
## `deflate_compress_greedy` and `deflate_compress_lazy_generic`.
##
## Greedy takes the longest match at each position. Lazy first checks whether
## the next position starts a better one and, if so, emits a literal and moves
## there instead; lazy2 looks one position further still. The comparison is not
## on length alone: a longer match only wins if it beats the incumbent by
## enough to pay for the literal, and a nearer offset counts in the incumbent's
## favour, since near offsets cost fewer bits.
CompressLazy := [].{

	## Blocks shorter than this are not worth their Huffman header.
	min_block_length : U64
	min_block_length = 5000

	## The length at which the parser tries to end a block.
	soft_max_block_length : U64
	soft_max_block_length = 300000

	## Matches a block may hold before it must be ended.
	seq_store_length : U64
	seq_store_length = 50000

	num_observation_types : U64
	num_observation_types = 10

	observations_per_block_check : U64
	observations_per_block_check = 512

	Params : { max_search_depth : U64, nice_match_length : U64, lazy : U64 }

	## Minimum match length as a function of how many distinct literals the
	## data uses.
	##
	## Data with many distinct literals has expensive literals, so short
	## matches pay off; data with few has cheap literals, so they do not. A
	## shallow search cannot find long matches reliably, which caps the minimum
	## as well.
	choose_min_match_len : U64, U64 -> U64
	choose_min_match_len = |num_used_literals, max_search_depth| {
		min_lens = [
			9, 9, 9, 9, 9, 9, 8, 8, 7, 7, 6, 6, 6, 6, 6, 6,
			5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
			5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 4, 4, 4,
			4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
			4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
		]
		if num_used_literals >= 80 {
			3
		} else {
			var $min_len = (List.get(min_lens, num_used_literals) ?? 3.U8).to_u64()
			if max_search_depth < 16 {
				if max_search_depth < 5 {
					$min_len = $min_len.min(4)
				} else if max_search_depth < 10 {
					$min_len = $min_len.min(5)
				} else {
					$min_len = $min_len.min(7)
				}
			} else {
			}
			$min_len
		}
	}

	## First approximation of the minimum match length, from the distinct
	## literals in the first few kilobytes of the block.
	calculate_min_match_len : List(U8), U64, U64, U64 -> Try(U64, [CompressBug])
	calculate_min_match_len = |data, at, data_len0, max_search_depth| {
		if data_len0 < 512 {
			# Short inputs often end up as static Huffman blocks, where short
			# matches cost nothing extra.
			Ok(DeflateTables.min_match_len)
		} else {
			data_len = data_len0.min(4096)
			var $used = List.repeat(0.U8, 256)
			var $i = 0.U64
			while $i < data_len {
				b = (List.get(data, at + $i) ?? 0).to_u64()
				$used = match List.set($used, b, 1) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				$i = $i + 1
			}
			var $num_used = 0.U64
			$i = 0
			while $i < 256 {
				$num_used = $num_used + (List.get($used, $i) ?? 0).to_u64()
				$i = $i + 1
			}
			Ok(CompressLazy.choose_min_match_len($num_used, max_search_depth))
		}
	}

	## Revise the minimum match length once the block's own literal
	## distribution is known, ignoring literals that barely occur.
	recalculate_min_match_len : List(U32), U64 -> U64
	recalculate_min_match_len = |freqs_litlen, max_search_depth| {
		var $literal_freq = 0.U64
		var $i = 0.U64
		while $i < DeflateTables.num_literals {
			$literal_freq = $literal_freq + (List.get(freqs_litlen, $i) ?? 0).to_u64()
			$i = $i + 1
		}
		cutoff = $literal_freq.shr_zf_wrap(10)
		var $num_used = 0.U64
		$i = 0
		while $i < DeflateTables.num_literals {
			if (List.get(freqs_litlen, $i) ?? 0).to_u64() > cutoff {
				$num_used = $num_used + 1
			} else {
			}
			$i = $i + 1
		}
		CompressLazy.choose_min_match_len($num_used, max_search_depth)
	}

	## Where a block would end if nothing else ended it first. A block that
	## would leave too short a remainder simply runs to the end of the input.
	choose_max_block_end : U64, U64, U64 -> U64
	choose_max_block_end = |in_block_begin, in_end, soft_max_len|
		if in_end - in_block_begin < soft_max_len + CompressLazy.min_block_length {
			in_end
		} else {
			in_block_begin + soft_max_len
		}

	## Decide whether the symbols seen recently differ enough from those seen
	## earlier in the block to be worth a new Huffman code.
	##
	## The test is the sum of absolute differences between the two
	## distributions, scaled so no division is needed, against a cutoff that
	## grows with block length. Very short blocks pay a surcharge, since their
	## header is a larger share of their cost. This only reads the counts; a
	## caller that decides to continue the block folds them with
	## `merge_observations` itself.
	do_end_block_check : List(U32), List(U32), U64, U64, U64 -> U64
	do_end_block_check = |new_observations, observations, num_new_observations, num_observations, block_length| {
		if num_observations > 0 {
			var $total_delta = 0.U64
			var $i = 0.U64
			while $i < CompressLazy.num_observation_types {
				expected = (List.get(observations, $i) ?? 0).to_u64() * num_new_observations
				actual = (List.get(new_observations, $i) ?? 0).to_u64() * num_observations
				delta = if actual > expected { actual - expected } else { expected - actual }
				$total_delta = $total_delta + delta
				$i = $i + 1
			}
			num_items = num_observations + num_new_observations
			var $cutoff = num_new_observations * 200 // 512 * num_observations
			if block_length < 10000 and num_items < 8192 {
				$cutoff = $cutoff + $cutoff * (8192 - num_items) // 8192
			} else {
			}
			if $total_delta + (block_length // 4096) * num_observations >= $cutoff {
				1
			} else {
				0
			}
		} else {
			0
		}
	}

	MergedObservations : {
		new_observations : List(U32),
		observations : List(U32),
		num_new_observations : U64,
		num_observations : U64,
	}

	merge_observations : List(U32), List(U32), U64, U64 -> Try(MergedObservations, [CompressBug])
	merge_observations = |new_observations_0, observations_0, num_new_observations, num_observations| {
		var $observations = observations_0
		var $new_observations = new_observations_0
		var $i = 0.U64
		while $i < CompressLazy.num_observation_types {
			merged = (List.get($observations, $i) ?? 0) + (List.get($new_observations, $i) ?? 0)
			$observations = match List.set($observations, $i, merged) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$new_observations = match List.set($new_observations, $i, 0) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$i = $i + 1
		}
		Ok({
			observations: $observations,
			new_observations: $new_observations,
			num_observations: num_observations + num_new_observations,
			num_new_observations: 0,
		})
	}
	## The static Huffman code RFC 1951 defines, built once per stream so a
	## block can be costed against it.
	build_static_codes : U64 -> Try(BlockOut.Codes, [CompressBug])
	build_static_codes = |_unused| {
		var $freqs_litlen = List.repeat(0.U32, DeflateTables.num_litlen_syms)
		var $i = 0.U64
		while $i < DeflateTables.num_litlen_syms {
			f =
				if $i < 144 {
					2
				} else if $i < 256 {
					1
				} else if $i < 280 {
					4
				} else {
					2
				}
			$freqs_litlen = match List.set($freqs_litlen, $i, f) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$i = $i + 1
		}
		litlen = HuffmanEncode.make_code(
			DeflateTables.num_litlen_syms,
			BlockOut.max_litlen_codeword_len,
			$freqs_litlen,
			List.repeat(0.U8, DeflateTables.num_litlen_syms),
			List.repeat(0.U32, DeflateTables.num_litlen_syms),
		)?
		offset = HuffmanEncode.make_code(
			DeflateTables.num_offset_syms,
			BlockOut.max_offset_codeword_len,
			List.repeat(1.U32, DeflateTables.num_offset_syms),
			List.repeat(0.U8, DeflateTables.num_offset_syms),
			List.repeat(0.U32, DeflateTables.num_offset_syms),
		)?
		Ok({
			litlen_lens: litlen.lens,
			litlen_codewords: litlen.codewords,
			offset_lens: offset.lens,
			offset_codewords: offset.codewords,
		})
	}

	## Index of the highest set bit, which stands in for the cost of an offset:
	## each extra bit of magnitude is roughly one more bit on the wire.
	bsr32 : U64 -> I64
	bsr32 = |x| 31 - x.to_u32_wrap().count_leading_zero_bits().to_i64()

	## Compress with the greedy parser, which always takes the longest match
	## at the current position.
	##
	## Unlike the lazy parser this never looks ahead, so it has no reason to
	## revise the minimum match length mid-block either.
	compress_greedy : List(U8), Params -> Try(List(U8), [CompressBug])
	compress_greedy = |input, params| {
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
		var $nice_len = params.nice_match_length.min(DeflateTables.max_match_len)
		# The matchfinder tables are held as separate values rather than one
		# record: a record of lists is copied whenever it crosses a call
		# boundary, which at these sizes would dwarf the search itself.
		var $mf = HcMatchfinder.init_tables({})
		var $base = 0.U64
		var $nh3 = 0.U64
		var $nh4 = 0.U64
		# One allocation for the whole stream: a block appends its sequences and
		# the run terminator, and clearing the list afterwards keeps the capacity.
		# A block holds at most one sequence per input byte, so a short input
		# needs no more than that.
		var $seqs = List.with_capacity(CompressLazy.seq_store_length.min(in_end) + 1)

		var $blocking = 1.U64
		while $blocking == 1 {
			in_block_begin = $in_next
			in_max_block_end = CompressLazy.choose_max_block_end(
				$in_next,
				in_end,
				CompressLazy.soft_max_block_length,
			)
			var $new_observations = List.repeat(0.U32, CompressLazy.num_observation_types)
			var $observations = List.repeat(0.U32, CompressLazy.num_observation_types)
			var $num_new_observations = 0.U64
			var $num_observations = 0.U64
			var $freqs_litlen = List.repeat(0.U32, DeflateTables.num_litlen_syms)
			var $freqs_offset = List.repeat(0.U32, DeflateTables.num_offset_syms)
			$seqs = List.clear($seqs)
			# The tables hold all three regions for the whole block: the block's
			# writes only replace entries and the slide keeps the length, so stating
			# the size once here lets every table write in the block skip its
			# bounds test.
			if List.len($mf) < HcMatchfinder.table_size {
				return Err(CompressBug)
			} else {
			}
			var $litrunlen = 0.U32
			min_len = CompressLazy.calculate_min_match_len(
				input,
				$in_next,
				in_max_block_end - $in_next,
				params.max_search_depth,
			)?

			# Wrapping arithmetic on the per-position path: the cursor never passes
			# the input end, a match is at least three bytes and at most 258, the
			# window base never passes the cursor, and every run length and symbol
			# count stays below the block length, so a checked add or subtract here
			# would only put an overflow branch on every position.
			var $in_block = 1.U64
			while $in_block == 1 {
				remaining = in_end.minus_wrap($in_next)
				if remaining < DeflateTables.max_match_len {
					$max_len = remaining
					$nice_len = $nice_len.min($max_len)
				} else {
				}

				# Slide the tables when the window has moved one whole window past
				# the base, then insert this position before searching: the chain
				# heads read here are the ones from before the insert, so the walk
				# starts at the previous occurrence rather than at this position.
				if $in_next.minus_wrap($base) == Matchfinder.window_size {
					$mf = Matchfinder.rebase_nodes($mf)
					$base = $base.plus_wrap(Matchfinder.window_size)
				} else {
				}
				var $found = { length: min_len.minus_wrap(1), offset: 0.U64 }
				if $max_len < 5 {
					# Not enough bytes left to read the next position's hash sequence.
				} else {
					cur_pos = $in_next.minus_wrap($base)
					cur_node3 = List.get($mf, HcMatchfinder.hash3_base.plus_wrap($nh3)) ?? 0
					cur_node4 = List.get($mf, HcMatchfinder.hash4_base.plus_wrap($nh4)) ?? 0
					pos = (cur_pos.plus_wrap(Matchfinder.node_bias)).to_u16_wrap()
					$mf = match List.set($mf, HcMatchfinder.hash3_base.plus_wrap($nh3), pos) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$mf = match List.set($mf, HcMatchfinder.hash4_base.plus_wrap($nh4), pos) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$mf = match List.set($mf, cur_pos, cur_node4) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					next_hashseq = U32.from_le_bytes(input, $in_next.plus_wrap(1)) ?? 0
					$nh3 = Matchfinder.lz_hash(next_hashseq.bitwise_and(0xFFFFFF), HcMatchfinder.hash3_order)
					$nh4 = Matchfinder.lz_hash(next_hashseq, HcMatchfinder.hash4_order)
					# The hash-chain search, written out here rather than called: it is
					# the greedy loop's whole body, and as a call it returned its match
					# through memory and spilled the loop's state around itself.
					# The chain region is one window long, so every masked chain index is
					# in range, and a length guard here would let each chain read's bounds
					# test fold away. It is deliberately absent: the test costs nothing on
					# the walk's critical path, while its survival keeps the masked index
					# as a separate value that the load then scales for free. Folded, the
					# mask and scale merge into one instruction ahead of the load, which
					# is a cycle more on every step of the chain.
					# A node at or below the current position, in the biased space the
					# tables use, is out of the window.

					var $best_len = min_len.minus_wrap(1)
					var $best_match_at = $in_next

					seq4 = U32.from_le_bytes(input, $in_next) ?? 0
					var $node4 = cur_node4
					var $depth = params.max_search_depth
					var $done = 0.U64

					if $best_len < 4 {
						if cur_node3.to_u64() <= cur_pos {
							$done = 1
						} else {
							if $best_len < 3 {
								match_at = Matchfinder.node_index($base, cur_node3)
								if (U32.from_le_bytes(input, match_at) ?? 0).bitwise_and(0xFFFFFF)
									== seq4.bitwise_and(0xFFFFFF) {
									$best_len = 3
									$best_match_at = match_at
								} else {
								}
							} else {
							}

							if $node4.to_u64() <= cur_pos {
								$done = 1
							} else {
								# Walk the chain until four bytes agree.
								var $found_at = 0.U64
								while True {
									match_at = Matchfinder.node_index($base, $node4)
									if (U32.from_le_bytes(input, match_at) ?? 0) == seq4 {
										$found_at = match_at
										break
									} else {
									}
									$node4 = List.get($mf, $node4.to_u64().bitwise_and(32767)) ?? 0
									$depth = $depth.minus_wrap(1)
									if $node4.to_u64() <= cur_pos or $depth == 0 {
										$done = 1
										break
									} else {
									}
								}

								if $done == 0 {
									$best_match_at = $found_at
									$best_len = Matchfinder.lz_extend(input, $in_next, $found_at, 4, $max_len)
									if $best_len >= $nice_len {
										$done = 1
									} else {
										$node4 = List.get($mf, $node4.to_u64().bitwise_and(32767)) ?? 0
										$depth = $depth.minus_wrap(1)
										if $node4.to_u64() <= cur_pos or $depth == 0 {
											$done = 1
										} else {
										}
									}
								} else {
								}
							}
						}
					} else {
						if $node4.to_u64() <= cur_pos or $best_len >= $nice_len {
							$done = 1
						} else {
						}
					}

					# Now look only for matches longer than the one in hand.
					while $done == 0 {
						var $cand_at = 0.U64
						while True {
							match_at = Matchfinder.node_index($base, $node4)
							# The four bytes ending just past the current best length
							# are what a longer match must agree on, so check them
							# before anything else.
							# Wrapping arithmetic: positions are far below 2^63, and a checked
							# add or subtract would put an overflow branch on every candidate.
							if (U32.from_le_bytes(input, match_at.plus_wrap($best_len).minus_wrap(3)) ?? 0)
								== (U32.from_le_bytes(input, $in_next.plus_wrap($best_len).minus_wrap(3)) ?? 0)
								and (U32.from_le_bytes(input, match_at) ?? 0) == seq4 {
								$cand_at = match_at
								break
							} else {
							}
							$node4 = List.get($mf, $node4.to_u64().bitwise_and(32767)) ?? 0
							$depth = $depth.minus_wrap(1)
							if $node4.to_u64() <= cur_pos or $depth == 0 {
								$done = 1
								break
							} else {
							}
						}

						if $done == 0 {
							len = Matchfinder.lz_extend(input, $in_next, $cand_at, 4, $max_len)
							if len > $best_len {
								$best_len = len
								$best_match_at = $cand_at
								if $best_len >= $nice_len {
									$done = 1
								} else {
								}
							} else {
							}
							if $done == 0 {
								$node4 = List.get($mf, $node4.to_u64().bitwise_and(32767)) ?? 0
								$depth = $depth.minus_wrap(1)
								if $node4.to_u64() <= cur_pos or $depth == 0 {
									$done = 1
								} else {
								}
							} else {
							}
						} else {
						}
					}

					$found = { length: $best_len, offset: $in_next.minus_wrap($best_match_at) }
				}

				if $found.length >= min_len
					and ($found.length > DeflateTables.min_match_len or $found.offset <= 4096) {
					length_slot = DeflateTables.length_slot($found.length)
					offset_slot = DeflateTables.offset_slot($found.offset)
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
					obs = if $found.length >= 9 { 9 } else { 8 }
					obs_count = (List.get($new_observations, obs) ?? 0).plus_wrap(1)
					$new_observations = match List.set($new_observations, obs, obs_count) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$num_new_observations = $num_new_observations.plus_wrap(1)
					$seqs = List.append($seqs, {
						litrunlen_and_length: $litrunlen.bitwise_or($found.length.to_u32_wrap().shl_wrap(BlockOut.seq_length_shift)),
						offset: $found.offset.to_u16_wrap(),
						offset_slot: offset_slot.to_u16_wrap(),
					})
					$litrunlen = 0

					skipped = HcMatchfinder.skip_bytes($mf, $base, $nh3, $nh4, input, $in_next.plus_wrap(1), in_end, $found.length.minus_wrap(1))?
					$mf = skipped.tab
					$base = skipped.in_cur_base
					$nh3 = skipped.next_hash3
					$nh4 = skipped.next_hash4
					$in_next = $in_next.plus_wrap($found.length)
				} else {
					lit = (List.get(input, $in_next) ?? 0).to_u64()
					lit_count = (List.get($freqs_litlen, lit) ?? 0).plus_wrap(1)
					$freqs_litlen = match List.set($freqs_litlen, lit, lit_count) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					obs = lit.shr_zf_wrap(5).bitwise_and(0x6).bitwise_or(lit.bitwise_and(1))
					obs_count = (List.get($new_observations, obs) ?? 0).plus_wrap(1)
					$new_observations = match List.set($new_observations, obs, obs_count) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$num_new_observations = $num_new_observations.plus_wrap(1)
					$litrunlen = $litrunlen.plus_wrap(1)
					$in_next = $in_next.plus_wrap(1)
				}

				if $in_next >= in_max_block_end or List.len($seqs) >= CompressLazy.seq_store_length {
					$in_block = 0
				} else if $num_new_observations >= CompressLazy.observations_per_block_check
					and $in_next.minus_wrap(in_block_begin) >= CompressLazy.min_block_length
					and in_end.minus_wrap($in_next) >= CompressLazy.min_block_length {
					if CompressLazy.do_end_block_check($new_observations, $observations, $num_new_observations, $num_observations, $in_next.minus_wrap(in_block_begin)) == 1 {
						$in_block = 0
					} else {
						ms = CompressLazy.merge_observations($new_observations, $observations, $num_new_observations, $num_observations)?
						$new_observations = ms.new_observations
						$observations = ms.observations
						$num_new_observations = ms.num_new_observations
						$num_observations = ms.num_observations
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

	## Compress with the greedy or lazy parser.
	##
	## `params.lazy` selects how far ahead the parser looks before committing to
	## a match: zero is greedy, one is lazy, two is lazy2.
	compress : List(U8), Params -> Try(List(U8), [CompressBug])
	compress = |input, params| {
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
		var $nice_len = params.nice_match_length.min(DeflateTables.max_match_len)
		# The matchfinder tables are held as separate values rather than one
		# record: a record of lists is copied whenever it crosses a call
		# boundary, which at these sizes would dwarf the search itself.
		var $mf = HcMatchfinder.init_tables({})
		var $base = 0.U64
		var $nh3 = 0.U64
		var $nh4 = 0.U64
		# One allocation for the whole stream: a block appends its sequences and
		# the run terminator, and clearing the list afterwards keeps the capacity.
		# A block holds at most one sequence per input byte, so a short input
		# needs no more than that.
		var $seqs = List.with_capacity(CompressLazy.seq_store_length.min(in_end) + 1)

		var $blocking = 1.U64
		while $blocking == 1 {
			# Starting a new block.
			in_block_begin = $in_next
			in_max_block_end = CompressLazy.choose_max_block_end(
				$in_next,
				in_end,
				CompressLazy.soft_max_block_length,
			)
			var $next_recalc_min_len = $in_next + (in_end - $in_next).min(10000)
			var $new_observations = List.repeat(0.U32, CompressLazy.num_observation_types)
			var $observations = List.repeat(0.U32, CompressLazy.num_observation_types)
			var $num_new_observations = 0.U64
			var $num_observations = 0.U64
			var $freqs_litlen = List.repeat(0.U32, DeflateTables.num_litlen_syms)
			var $freqs_offset = List.repeat(0.U32, DeflateTables.num_offset_syms)
			$seqs = List.clear($seqs)
			# The tables hold all three regions for the whole block: the block's
			# writes only replace entries and the slide keeps the length, so stating
			# the size once here lets every table write in the block skip its
			# bounds test.
			if List.len($mf) < HcMatchfinder.table_size {
				return Err(CompressBug)
			} else {
			}
			var $litrunlen = 0.U32
			var $min_len = CompressLazy.calculate_min_match_len(
				input,
				$in_next,
				in_max_block_end - $in_next,
				params.max_search_depth,
			)?

			# Wrapping arithmetic on the per-position path: the cursor never passes
			# the input end, a match is at least three bytes and at most 258, the
			# window base never passes the cursor, and every run length and symbol
			# count stays below the block length, so a checked add or subtract here
			# would only put an overflow branch on every position.
			var $in_block = 1.U64
			while $in_block == 1 {
				# Revise the minimum match length once enough of the block has
				# been seen for its own literal distribution to mean something.
				if $in_next >= $next_recalc_min_len {
					$min_len = CompressLazy.recalculate_min_match_len($freqs_litlen, params.max_search_depth)
					$next_recalc_min_len = $next_recalc_min_len.plus_wrap(in_end.minus_wrap($next_recalc_min_len).min($in_next.minus_wrap(in_block_begin)))
				} else {
				}

				remaining0 = in_end.minus_wrap($in_next)
				if remaining0 < DeflateTables.max_match_len {
					$max_len = remaining0
					$nice_len = $nice_len.min($max_len)
				} else {
				}

				# Slide the tables when the window has moved one whole window past
				# the base, then insert this position before searching: the chain
				# heads read here are the ones from before the insert, so the walk
				# starts at the previous occurrence rather than at this position.
				if $in_next.minus_wrap($base) == Matchfinder.window_size {
					$mf = Matchfinder.rebase_nodes($mf)
					$base = $base.plus_wrap(Matchfinder.window_size)
				} else {
				}
				var $found = { length: $min_len.minus_wrap(1), offset: 0.U64 }
				if $max_len < 5 {
					# Not enough bytes left to read the next position's hash sequence.
				} else {
					cur_pos = $in_next.minus_wrap($base)
					cur_node3 = List.get($mf, HcMatchfinder.hash3_base.plus_wrap($nh3)) ?? 0
					cur_node4 = List.get($mf, HcMatchfinder.hash4_base.plus_wrap($nh4)) ?? 0
					pos = (cur_pos.plus_wrap(Matchfinder.node_bias)).to_u16_wrap()
					$mf = match List.set($mf, HcMatchfinder.hash3_base.plus_wrap($nh3), pos) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$mf = match List.set($mf, HcMatchfinder.hash4_base.plus_wrap($nh4), pos) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$mf = match List.set($mf, cur_pos, cur_node4) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					next_hashseq = U32.from_le_bytes(input, $in_next.plus_wrap(1)) ?? 0
					$nh3 = Matchfinder.lz_hash(next_hashseq.bitwise_and(0xFFFFFF), HcMatchfinder.hash3_order)
					$nh4 = Matchfinder.lz_hash(next_hashseq, HcMatchfinder.hash4_order)
					# The hash-chain search, written out here rather than called, so the
					# loop's state stays in registers across it.
					# The chain region is one window long, so every masked chain index is
					# in range, and a length guard here would let each chain read's bounds
					# test fold away. It is deliberately absent: the test costs nothing on
					# the walk's critical path, while its survival keeps the masked index
					# as a separate value that the load then scales for free. Folded, the
					# mask and scale merge into one instruction ahead of the load, which
					# is a cycle more on every step of the chain.
					# A node at or below the current position, in the biased space the
					# tables use, is out of the window.

					var $best_len_s = $min_len.minus_wrap(1)
					var $best_match_at_s = $in_next

					seq4_s = U32.from_le_bytes(input, $in_next) ?? 0
					var $node4_s = cur_node4
					var $depth_s = params.max_search_depth
					var $done_s = 0.U64

					if $best_len_s < 4 {
						if cur_node3.to_u64() <= cur_pos {
							$done_s = 1
						} else {
							if $best_len_s < 3 {
								match_at_s = Matchfinder.node_index($base, cur_node3)
								if (U32.from_le_bytes(input, match_at_s) ?? 0).bitwise_and(0xFFFFFF)
									== seq4_s.bitwise_and(0xFFFFFF) {
									$best_len_s = 3
									$best_match_at_s = match_at_s
								} else {
								}
							} else {
							}

							if $node4_s.to_u64() <= cur_pos {
								$done_s = 1
							} else {
								# Walk the chain until four bytes agree.
								var $found_at_s = 0.U64
								while True {
									match_at_s = Matchfinder.node_index($base, $node4_s)
									if (U32.from_le_bytes(input, match_at_s) ?? 0) == seq4_s {
										$found_at_s = match_at_s
										break
									} else {
									}
									$node4_s = List.get($mf, $node4_s.to_u64().bitwise_and(32767)) ?? 0
									$depth_s = $depth_s.minus_wrap(1)
									if $node4_s.to_u64() <= cur_pos or $depth_s == 0 {
										$done_s = 1
										break
									} else {
									}
								}

								if $done_s == 0 {
									$best_match_at_s = $found_at_s
									$best_len_s = Matchfinder.lz_extend(input, $in_next, $found_at_s, 4, $max_len)
									if $best_len_s >= $nice_len {
										$done_s = 1
									} else {
										$node4_s = List.get($mf, $node4_s.to_u64().bitwise_and(32767)) ?? 0
										$depth_s = $depth_s.minus_wrap(1)
										if $node4_s.to_u64() <= cur_pos or $depth_s == 0 {
											$done_s = 1
										} else {
										}
									}
								} else {
								}
							}
						}
					} else {
						if $node4_s.to_u64() <= cur_pos or $best_len_s >= $nice_len {
							$done_s = 1
						} else {
						}
					}

					# Now look only for matches longer than the one in hand.
					while $done_s == 0 {
						var $cand_at_s = 0.U64
						while True {
							match_at_s = Matchfinder.node_index($base, $node4_s)
							# The four bytes ending just past the current best length
							# are what a longer match must agree on, so check them
							# before anything else.
							# Wrapping arithmetic: positions are far below 2^63, and a checked
							# add or subtract would put an overflow branch on every candidate.
							if (U32.from_le_bytes(input, match_at_s.plus_wrap($best_len_s).minus_wrap(3)) ?? 0)
								== (U32.from_le_bytes(input, $in_next.plus_wrap($best_len_s).minus_wrap(3)) ?? 0)
								and (U32.from_le_bytes(input, match_at_s) ?? 0) == seq4_s {
								$cand_at_s = match_at_s
								break
							} else {
							}
							$node4_s = List.get($mf, $node4_s.to_u64().bitwise_and(32767)) ?? 0
							$depth_s = $depth_s.minus_wrap(1)
							if $node4_s.to_u64() <= cur_pos or $depth_s == 0 {
								$done_s = 1
								break
							} else {
							}
						}

						if $done_s == 0 {
							len_s = Matchfinder.lz_extend(input, $in_next, $cand_at_s, 4, $max_len)
							if len_s > $best_len_s {
								$best_len_s = len_s
								$best_match_at_s = $cand_at_s
								if $best_len_s >= $nice_len {
									$done_s = 1
								} else {
								}
							} else {
							}
							if $done_s == 0 {
								$node4_s = List.get($mf, $node4_s.to_u64().bitwise_and(32767)) ?? 0
								$depth_s = $depth_s.minus_wrap(1)
								if $node4_s.to_u64() <= cur_pos or $depth_s == 0 {
									$done_s = 1
								} else {
								}
							} else {
							}
						} else {
						}
					}

					$found = { length: $best_len_s, offset: $in_next.minus_wrap($best_match_at_s) }
				}

				if $found.length < $min_len
					or ($found.length == DeflateTables.min_match_len and $found.offset > 8192) {
					# No match worth taking; emit a literal.
					lit = (List.get(input, $in_next) ?? 0).to_u64()
					lit_count = (List.get($freqs_litlen, lit) ?? 0).plus_wrap(1)
					$freqs_litlen = match List.set($freqs_litlen, lit, lit_count) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					obs = lit.shr_zf_wrap(5).bitwise_and(0x6).bitwise_or(lit.bitwise_and(1))
					obs_count = (List.get($new_observations, obs) ?? 0).plus_wrap(1)
					$new_observations = match List.set($new_observations, obs, obs_count) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$num_new_observations = $num_new_observations.plus_wrap(1)
					$litrunlen = $litrunlen.plus_wrap(1)
					$in_next = $in_next.plus_wrap(1)
				} else {
					$in_next = $in_next.plus_wrap(1)
					var $cur_len = $found.length
					var $cur_offset = $found.offset

					# Hold the match while looking for a better one just ahead. The
					# loop only decides which match to take and how far to skip past
					# it; the match is recorded after the loop.
					# TODO(roc-lang/roc#11933): recording it inside the loop, after
					# the `if` that chooses it, made `--opt=dev` builds copy the
					# frequency tables and the matchfinder table once per match.
					var $matching = 1.U64
					var $skip_after = 0.U64
					while $matching == 1 {
						if $cur_len >= $nice_len {
							# Long enough that looking further cannot pay.
							$matching = 0
							$skip_after = $cur_len.minus_wrap(1)
						} else {
							remaining1 = in_end.minus_wrap($in_next)
							if remaining1 < DeflateTables.max_match_len {
								$max_len = remaining1
								$nice_len = $nice_len.min($max_len)
							} else {
								}
							# Half the search depth here: the initial match is
							# worth more effort than the lookahead.
							# Slide the tables when the window has moved one whole window past
							# the base, then insert this position before searching: the chain
							# heads read here are the ones from before the insert, so the walk
							# starts at the previous occurrence rather than at this position.
							if $in_next.minus_wrap($base) == Matchfinder.window_size {
								$mf = Matchfinder.rebase_nodes($mf)
								$base = $base.plus_wrap(Matchfinder.window_size)
							} else {
							}
							var $nxt = { length: $cur_len.minus_wrap(1), offset: 0.U64 }
							if $max_len < 5 {
								# Not enough bytes left to read the next position's hash sequence.
							} else {
								cur_pos = $in_next.minus_wrap($base)
								cur_node3 = List.get($mf, HcMatchfinder.hash3_base.plus_wrap($nh3)) ?? 0
								cur_node4 = List.get($mf, HcMatchfinder.hash4_base.plus_wrap($nh4)) ?? 0
								pos = (cur_pos.plus_wrap(Matchfinder.node_bias)).to_u16_wrap()
								$mf = match List.set($mf, HcMatchfinder.hash3_base.plus_wrap($nh3), pos) {
									Ok(next) => next
									Err(_) => return Err(CompressBug)
								}
								$mf = match List.set($mf, HcMatchfinder.hash4_base.plus_wrap($nh4), pos) {
									Ok(next) => next
									Err(_) => return Err(CompressBug)
								}
								$mf = match List.set($mf, cur_pos, cur_node4) {
									Ok(next) => next
									Err(_) => return Err(CompressBug)
								}
								next_hashseq = U32.from_le_bytes(input, $in_next.plus_wrap(1)) ?? 0
								$nh3 = Matchfinder.lz_hash(next_hashseq.bitwise_and(0xFFFFFF), HcMatchfinder.hash3_order)
								$nh4 = Matchfinder.lz_hash(next_hashseq, HcMatchfinder.hash4_order)
								# The hash-chain search, written out here rather than called, so the
								# loop's state stays in registers across it.
								# The chain region is one window long, so every masked chain index is
								# in range, and a length guard here would let each chain read's bounds
								# test fold away. It is deliberately absent: the test costs nothing on
								# the walk's critical path, while its survival keeps the masked index
								# as a separate value that the load then scales for free. Folded, the
								# mask and scale merge into one instruction ahead of the load, which
								# is a cycle more on every step of the chain.
								# A node at or below the current position, in the biased space the
								# tables use, is out of the window.

								var $best_len_n = $cur_len.minus_wrap(1)
								var $best_match_at_n = $in_next

								seq4_n = U32.from_le_bytes(input, $in_next) ?? 0
								var $node4_n = cur_node4
								var $depth_n = params.max_search_depth.shr_zf_wrap(1)
								var $done_n = 0.U64

								if $best_len_n < 4 {
									if cur_node3.to_u64() <= cur_pos {
										$done_n = 1
									} else {
										if $best_len_n < 3 {
											match_at_n = Matchfinder.node_index($base, cur_node3)
											if (U32.from_le_bytes(input, match_at_n) ?? 0).bitwise_and(0xFFFFFF)
												== seq4_n.bitwise_and(0xFFFFFF) {
												$best_len_n = 3
												$best_match_at_n = match_at_n
											} else {
											}
										} else {
										}

										if $node4_n.to_u64() <= cur_pos {
											$done_n = 1
										} else {
											# Walk the chain until four bytes agree.
											var $found_at_n = 0.U64
											while True {
												match_at_n = Matchfinder.node_index($base, $node4_n)
												if (U32.from_le_bytes(input, match_at_n) ?? 0) == seq4_n {
													$found_at_n = match_at_n
													break
												} else {
												}
												$node4_n = List.get($mf, $node4_n.to_u64().bitwise_and(32767)) ?? 0
												$depth_n = $depth_n.minus_wrap(1)
												if $node4_n.to_u64() <= cur_pos or $depth_n == 0 {
													$done_n = 1
													break
												} else {
												}
											}

											if $done_n == 0 {
												$best_match_at_n = $found_at_n
												$best_len_n = Matchfinder.lz_extend(input, $in_next, $found_at_n, 4, $max_len)
												if $best_len_n >= $nice_len {
													$done_n = 1
												} else {
													$node4_n = List.get($mf, $node4_n.to_u64().bitwise_and(32767)) ?? 0
													$depth_n = $depth_n.minus_wrap(1)
													if $node4_n.to_u64() <= cur_pos or $depth_n == 0 {
														$done_n = 1
													} else {
													}
												}
											} else {
											}
										}
									}
								} else {
									if $node4_n.to_u64() <= cur_pos or $best_len_n >= $nice_len {
										$done_n = 1
									} else {
									}
								}

								# Now look only for matches longer than the one in hand.
								while $done_n == 0 {
									var $cand_at_n = 0.U64
									while True {
										match_at_n = Matchfinder.node_index($base, $node4_n)
										# The four bytes ending just past the current best length
										# are what a longer match must agree on, so check them
										# before anything else.
										# Wrapping arithmetic: positions are far below 2^63, and a checked
										# add or subtract would put an overflow branch on every candidate.
										if (U32.from_le_bytes(input, match_at_n.plus_wrap($best_len_n).minus_wrap(3)) ?? 0)
											== (U32.from_le_bytes(input, $in_next.plus_wrap($best_len_n).minus_wrap(3)) ?? 0)
											and (U32.from_le_bytes(input, match_at_n) ?? 0) == seq4_n {
											$cand_at_n = match_at_n
											break
										} else {
										}
										$node4_n = List.get($mf, $node4_n.to_u64().bitwise_and(32767)) ?? 0
										$depth_n = $depth_n.minus_wrap(1)
										if $node4_n.to_u64() <= cur_pos or $depth_n == 0 {
											$done_n = 1
											break
										} else {
										}
									}

									if $done_n == 0 {
										len_n = Matchfinder.lz_extend(input, $in_next, $cand_at_n, 4, $max_len)
										if len_n > $best_len_n {
											$best_len_n = len_n
											$best_match_at_n = $cand_at_n
											if $best_len_n >= $nice_len {
												$done_n = 1
											} else {
											}
										} else {
										}
										if $done_n == 0 {
											$node4_n = List.get($mf, $node4_n.to_u64().bitwise_and(32767)) ?? 0
											$depth_n = $depth_n.minus_wrap(1)
											if $node4_n.to_u64() <= cur_pos or $depth_n == 0 {
												$done_n = 1
											} else {
											}
										} else {
										}
									} else {
									}
								}

								$nxt = { length: $best_len_n, offset: $in_next.minus_wrap($best_match_at_n) }
							}
							$in_next = $in_next.plus_wrap(1)

							better = $nxt.length >= $cur_len
								and $nxt.length.to_i64_wrap().minus_wrap($cur_len.to_i64_wrap()).times_wrap(4)
									.plus_wrap(CompressLazy.bsr32($cur_offset).minus_wrap(CompressLazy.bsr32($nxt.offset))) > 2

							if better {
								# The next position starts a better match, so
								# this position becomes a literal.
								lit = (List.get(input, $in_next.minus_wrap(2)) ?? 0).to_u64()
								lit_count = (List.get($freqs_litlen, lit) ?? 0).plus_wrap(1)
								$freqs_litlen = match List.set($freqs_litlen, lit, lit_count) {
									Ok(next) => next
									Err(_) => return Err(CompressBug)
								}
								obs = lit.shr_zf_wrap(5).bitwise_and(0x6).bitwise_or(lit.bitwise_and(1))
								obs_count = (List.get($new_observations, obs) ?? 0).plus_wrap(1)
								$new_observations = match List.set($new_observations, obs, obs_count) {
									Ok(next) => next
									Err(_) => return Err(CompressBug)
								}
								$num_new_observations = $num_new_observations.plus_wrap(1)
								$litrunlen = $litrunlen.plus_wrap(1)
								$cur_len = $nxt.length
								$cur_offset = $nxt.offset
							} else if params.lazy >= 2 {
								remaining2 = in_end.minus_wrap($in_next)
								if remaining2 < DeflateTables.max_match_len {
									$max_len = remaining2
									$nice_len = $nice_len.min($max_len)
								} else {
								}
								# Slide the tables when the window has moved one whole window past
								# the base, then insert this position before searching: the chain
								# heads read here are the ones from before the insert, so the walk
								# starts at the previous occurrence rather than at this position.
								if $in_next.minus_wrap($base) == Matchfinder.window_size {
									$mf = Matchfinder.rebase_nodes($mf)
									$base = $base.plus_wrap(Matchfinder.window_size)
								} else {
								}
								var $nxt2 = { length: $cur_len.minus_wrap(1), offset: 0.U64 }
								if $max_len < 5 {
									# Not enough bytes left to read the next position's hash sequence.
								} else {
									cur_pos = $in_next.minus_wrap($base)
									cur_node3 = List.get($mf, HcMatchfinder.hash3_base.plus_wrap($nh3)) ?? 0
									cur_node4 = List.get($mf, HcMatchfinder.hash4_base.plus_wrap($nh4)) ?? 0
									pos = (cur_pos.plus_wrap(Matchfinder.node_bias)).to_u16_wrap()
									$mf = match List.set($mf, HcMatchfinder.hash3_base.plus_wrap($nh3), pos) {
										Ok(next) => next
										Err(_) => return Err(CompressBug)
									}
									$mf = match List.set($mf, HcMatchfinder.hash4_base.plus_wrap($nh4), pos) {
										Ok(next) => next
										Err(_) => return Err(CompressBug)
									}
									$mf = match List.set($mf, cur_pos, cur_node4) {
										Ok(next) => next
										Err(_) => return Err(CompressBug)
									}
									next_hashseq = U32.from_le_bytes(input, $in_next.plus_wrap(1)) ?? 0
									$nh3 = Matchfinder.lz_hash(next_hashseq.bitwise_and(0xFFFFFF), HcMatchfinder.hash3_order)
									$nh4 = Matchfinder.lz_hash(next_hashseq, HcMatchfinder.hash4_order)
									# The hash-chain search, written out here rather than called, so the
									# loop's state stays in registers across it.
									# The chain region is one window long, so every masked chain index is
									# in range, and a length guard here would let each chain read's bounds
									# test fold away. It is deliberately absent: the test costs nothing on
									# the walk's critical path, while its survival keeps the masked index
									# as a separate value that the load then scales for free. Folded, the
									# mask and scale merge into one instruction ahead of the load, which
									# is a cycle more on every step of the chain.
									# A node at or below the current position, in the biased space the
									# tables use, is out of the window.

									var $best_len_m = $cur_len.minus_wrap(1)
									var $best_match_at_m = $in_next

									seq4_m = U32.from_le_bytes(input, $in_next) ?? 0
									var $node4_m = cur_node4
									var $depth_m = params.max_search_depth.shr_zf_wrap(2)
									var $done_m = 0.U64

									if $best_len_m < 4 {
										if cur_node3.to_u64() <= cur_pos {
											$done_m = 1
										} else {
											if $best_len_m < 3 {
												match_at_m = Matchfinder.node_index($base, cur_node3)
												if (U32.from_le_bytes(input, match_at_m) ?? 0).bitwise_and(0xFFFFFF)
													== seq4_m.bitwise_and(0xFFFFFF) {
													$best_len_m = 3
													$best_match_at_m = match_at_m
												} else {
												}
											} else {
											}

											if $node4_m.to_u64() <= cur_pos {
												$done_m = 1
											} else {
												# Walk the chain until four bytes agree.
												var $found_at_m = 0.U64
												while True {
													match_at_m = Matchfinder.node_index($base, $node4_m)
													if (U32.from_le_bytes(input, match_at_m) ?? 0) == seq4_m {
														$found_at_m = match_at_m
														break
													} else {
													}
													$node4_m = List.get($mf, $node4_m.to_u64().bitwise_and(32767)) ?? 0
													$depth_m = $depth_m.minus_wrap(1)
													if $node4_m.to_u64() <= cur_pos or $depth_m == 0 {
														$done_m = 1
														break
													} else {
													}
												}

												if $done_m == 0 {
													$best_match_at_m = $found_at_m
													$best_len_m = Matchfinder.lz_extend(input, $in_next, $found_at_m, 4, $max_len)
													if $best_len_m >= $nice_len {
														$done_m = 1
													} else {
														$node4_m = List.get($mf, $node4_m.to_u64().bitwise_and(32767)) ?? 0
														$depth_m = $depth_m.minus_wrap(1)
														if $node4_m.to_u64() <= cur_pos or $depth_m == 0 {
															$done_m = 1
														} else {
														}
													}
												} else {
												}
											}
										}
									} else {
										if $node4_m.to_u64() <= cur_pos or $best_len_m >= $nice_len {
											$done_m = 1
										} else {
										}
									}

									# Now look only for matches longer than the one in hand.
									while $done_m == 0 {
										var $cand_at_m = 0.U64
										while True {
											match_at_m = Matchfinder.node_index($base, $node4_m)
											# The four bytes ending just past the current best length
											# are what a longer match must agree on, so check them
											# before anything else.
											# Wrapping arithmetic: positions are far below 2^63, and a checked
											# add or subtract would put an overflow branch on every candidate.
											if (U32.from_le_bytes(input, match_at_m.plus_wrap($best_len_m).minus_wrap(3)) ?? 0)
												== (U32.from_le_bytes(input, $in_next.plus_wrap($best_len_m).minus_wrap(3)) ?? 0)
												and (U32.from_le_bytes(input, match_at_m) ?? 0) == seq4_m {
												$cand_at_m = match_at_m
												break
											} else {
											}
											$node4_m = List.get($mf, $node4_m.to_u64().bitwise_and(32767)) ?? 0
											$depth_m = $depth_m.minus_wrap(1)
											if $node4_m.to_u64() <= cur_pos or $depth_m == 0 {
												$done_m = 1
												break
											} else {
											}
										}

										if $done_m == 0 {
											len_m = Matchfinder.lz_extend(input, $in_next, $cand_at_m, 4, $max_len)
											if len_m > $best_len_m {
												$best_len_m = len_m
												$best_match_at_m = $cand_at_m
												if $best_len_m >= $nice_len {
													$done_m = 1
												} else {
												}
											} else {
											}
											if $done_m == 0 {
												$node4_m = List.get($mf, $node4_m.to_u64().bitwise_and(32767)) ?? 0
												$depth_m = $depth_m.minus_wrap(1)
												if $node4_m.to_u64() <= cur_pos or $depth_m == 0 {
													$done_m = 1
												} else {
												}
											} else {
											}
										} else {
										}
									}

									$nxt2 = { length: $best_len_m, offset: $in_next.minus_wrap($best_match_at_m) }
								}
								$in_next = $in_next.plus_wrap(1)

								better2 = $nxt2.length >= $cur_len
									and $nxt2.length.to_i64_wrap().minus_wrap($cur_len.to_i64_wrap()).times_wrap(4)
										.plus_wrap(CompressLazy.bsr32($cur_offset).minus_wrap(CompressLazy.bsr32($nxt2.offset))) > 6

								if better2 {
									# Two positions ahead is better still, so
									# both of these become literals.
									lit_a = (List.get(input, $in_next.minus_wrap(3)) ?? 0).to_u64()
									lit_a_count = (List.get($freqs_litlen, lit_a) ?? 0).plus_wrap(1)
									$freqs_litlen = match List.set($freqs_litlen, lit_a, lit_a_count) {
										Ok(next) => next
										Err(_) => return Err(CompressBug)
									}
									obs_a = lit_a.shr_zf_wrap(5).bitwise_and(0x6).bitwise_or(lit_a.bitwise_and(1))
									obs_a_count = (List.get($new_observations, obs_a) ?? 0).plus_wrap(1)
									$new_observations = match List.set($new_observations, obs_a, obs_a_count) {
										Ok(next) => next
										Err(_) => return Err(CompressBug)
									}
									$num_new_observations = $num_new_observations.plus_wrap(1)
									lit_b = (List.get(input, $in_next.minus_wrap(2)) ?? 0).to_u64()
									lit_b_count = (List.get($freqs_litlen, lit_b) ?? 0).plus_wrap(1)
									$freqs_litlen = match List.set($freqs_litlen, lit_b, lit_b_count) {
										Ok(next) => next
										Err(_) => return Err(CompressBug)
									}
									obs_b = lit_b.shr_zf_wrap(5).bitwise_and(0x6).bitwise_or(lit_b.bitwise_and(1))
									obs_b_count = (List.get($new_observations, obs_b) ?? 0).plus_wrap(1)
									$new_observations = match List.set($new_observations, obs_b, obs_b_count) {
										Ok(next) => next
										Err(_) => return Err(CompressBug)
									}
									$num_new_observations = $num_new_observations.plus_wrap(1)
									$litrunlen = $litrunlen.plus_wrap(2)
									$cur_len = $nxt2.length
									$cur_offset = $nxt2.offset
								} else {
									$matching = 0
									$skip_after = if $cur_len > 3 { $cur_len.minus_wrap(3) } else { 0 }
								}
							} else {
								$matching = 0
								$skip_after = $cur_len.minus_wrap(2)
							}
						}

					}

					# Record the match and insert the positions it covers.
					length_slot = DeflateTables.length_slot($cur_len)
					offset_slot = DeflateTables.offset_slot($cur_offset)
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
					obs = if $cur_len >= 9 { 9 } else { 8 }
					obs_count = (List.get($new_observations, obs) ?? 0).plus_wrap(1)
					$new_observations = match List.set($new_observations, obs, obs_count) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$num_new_observations = $num_new_observations.plus_wrap(1)
					$seqs = List.append($seqs, {
						litrunlen_and_length: $litrunlen.bitwise_or($cur_len.to_u32_wrap().shl_wrap(BlockOut.seq_length_shift)),
						offset: $cur_offset.to_u16_wrap(),
						offset_slot: offset_slot.to_u16_wrap(),
					})
					$litrunlen = 0
					if $skip_after > 0 {
						skipped = HcMatchfinder.skip_bytes($mf, $base, $nh3, $nh4, input, $in_next, in_end, $skip_after)?
						$mf = skipped.tab
						$base = skipped.in_cur_base
						$nh3 = skipped.next_hash3
						$nh4 = skipped.next_hash4
						$in_next = $in_next.plus_wrap($skip_after)
					} else {
					}
				}

				# Time to end the block?
				if $in_next >= in_max_block_end or List.len($seqs) >= CompressLazy.seq_store_length {
					$in_block = 0
				} else if $num_new_observations >= CompressLazy.observations_per_block_check
					and $in_next.minus_wrap(in_block_begin) >= CompressLazy.min_block_length
					and in_end.minus_wrap($in_next) >= CompressLazy.min_block_length {
					if CompressLazy.do_end_block_check($new_observations, $observations, $num_new_observations, $num_observations, $in_next.minus_wrap(in_block_begin)) == 1 {
						$in_block = 0
					} else {
						ms = CompressLazy.merge_observations($new_observations, $observations, $num_new_observations, $num_observations)?
						$new_observations = ms.new_observations
						$observations = ms.observations
						$num_new_observations = ms.num_new_observations
						$num_observations = ms.num_observations
					}
				} else {
				}
			}

			# Close the sequence list with the trailing literal run.
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

		# Any bits left over occupy one final byte.
		if $bitcount > 0 {
			$out = List.append($out, $bitbuf.to_u8_wrap())
		} else {
		}
		Ok($out)
	}
}
