import DeflateTables
import HuffmanEncode
import BlockOut
import Matchfinder
import BtMatchfinder
import CompressLazy

## The near-optimal DEFLATE parser, ported from libdeflate's
## `deflate_compress_near_optimal`.
##
## The greedy and lazy parsers decide each match as they reach it. This one
## first records, for every position in the block, every match the binary-tree
## matchfinder can find there, and only then chooses a sequence: the cheapest
## path through the block, where the cost of each literal and each match comes
## from a model of the Huffman codes.
##
## The catch is that the codes depend on the path and the path depends on the
## codes, so the block is parsed several times, each pass costing its path with
## the codes the previous pass produced. Two alternatives are costed alongside:
## a block of nothing but literals, and, for short blocks, the best path under
## the static Huffman codes.
CompressOptimal := [].{

	## Cost unit: costs are kept in sixteenths of a bit so that a model can
	## express fractional bits without floating point.
	bit_cost : U64
	bit_cost = 16

	## What a symbol is assumed to cost when the current codes do not use it at
	## all. Offsets get a lower number than literals and lengths because there
	## are far fewer offset symbols to spread the probability over.
	literal_nostat_bits : U64
	literal_nostat_bits = 13

	length_nostat_bits : U64
	length_nostat_bits = 13

	offset_nostat_bits : U64
	offset_nostat_bits = 10

	## A chosen item packs its length in the low nine bits and, above them,
	## either the match offset or, for a literal, the literal byte.
	optimum_offset_shift : U8
	optimum_offset_shift = 9

	optimum_len_mask : U32
	optimum_len_mask = 0x1FF

	## Matches the cache holds before the block must be ended. The slack past
	## it absorbs the worst case: a full position's worth of matches written
	## from the last slot, then a maximum-length match's worth of headers.
	match_cache_length : U64
	match_cache_length = 1500000

	## The matchfinder never reports two matches of the same length, so one of
	## each possible length bounds what a single position can produce.
	max_matches_per_pos : U64
	max_matches_per_pos = DeflateTables.max_match_len - DeflateTables.min_match_len + 1

	match_cache_size : U64
	match_cache_size = CompressOptimal.match_cache_length
		+ CompressOptimal.max_matches_per_pos
		+ DeflateTables.max_match_len
		- 1

	## One node per position plus one for the end of the block. The longest a
	## block can get is the soft maximum plus the shortest block that could
	## follow it, since a shorter remainder is folded into the current block.
	optimum_nodes_size : U64
	optimum_nodes_size = CompressLazy.soft_max_block_length + CompressLazy.min_block_length

	## Assumed cost of an offset symbol when nothing better is known, which is
	## `-log2(1/30)` in sixteenths of a bit, thirty being the offset symbols
	## that can actually occur.
	default_offset_sym_cost : U64
	default_offset_sym_cost = 78

	Params : {
		max_search_depth : U64,
		nice_match_length : U64,
		max_optim_passes : U64,
		min_improvement_to_continue : U64,
		min_bits_to_use_nonfinal_path : U64,
		max_len_to_optimize_static_block : U64,
	}

	## The default cost of a literal, in sixteenths of a bit, as a function of
	## how many distinct literals the data uses.
	##
	## The three tables are chosen by how match-heavy the data looks, since a
	## literal is cheaper when literals are what the block is mostly made of.
	## Within a table the cost is `-log2((1 - match_prob) / num_used_literals)`,
	## so literals get cheaper as fewer distinct ones appear.
	default_lit_cost_0 : List(U8)
	default_lit_cost_0 = [
		6, 6, 22, 32, 38, 43, 48, 51, 54, 57, 59, 61, 64, 65, 67, 69,
		70, 72, 73, 74, 75, 76, 77, 79, 80, 80, 81, 82, 83, 84, 85, 85,
		86, 87, 88, 88, 89, 89, 90, 91, 91, 92, 92, 93, 93, 94, 95, 95,
		96, 96, 96, 97, 97, 98, 98, 99, 99, 99, 100, 100, 101, 101, 101, 102,
		102, 102, 103, 103, 104, 104, 104, 105, 105, 105, 105, 106, 106, 106, 107, 107,
		107, 108, 108, 108, 108, 109, 109, 109, 109, 110, 110, 110, 111, 111, 111, 111,
		112, 112, 112, 112, 112, 113, 113, 113, 113, 114, 114, 114, 114, 114, 115, 115,
		115, 115, 115, 116, 116, 116, 116, 116, 117, 117, 117, 117, 117, 118, 118, 118,
		118, 118, 118, 119, 119, 119, 119, 119, 120, 120, 120, 120, 120, 120, 121, 121,
		121, 121, 121, 121, 121, 122, 122, 122, 122, 122, 122, 123, 123, 123, 123, 123,
		123, 123, 124, 124, 124, 124, 124, 124, 124, 125, 125, 125, 125, 125, 125, 125,
		125, 126, 126, 126, 126, 126, 126, 126, 127, 127, 127, 127, 127, 127, 127, 127,
		128, 128, 128, 128, 128, 128, 128, 128, 128, 129, 129, 129, 129, 129, 129, 129,
		129, 129, 130, 130, 130, 130, 130, 130, 130, 130, 130, 131, 131, 131, 131, 131,
		131, 131, 131, 131, 131, 132, 132, 132, 132, 132, 132, 132, 132, 132, 132, 133,
		133, 133, 133, 133, 133, 133, 133, 133, 133, 134, 134, 134, 134, 134, 134, 134,
		134
	]

	default_lit_cost_1 : List(U8)
	default_lit_cost_1 = [
		16, 16, 32, 41, 48, 53, 57, 60, 64, 66, 69, 71, 73, 75, 76, 78,
		80, 81, 82, 83, 85, 86, 87, 88, 89, 90, 91, 92, 92, 93, 94, 95,
		96, 96, 97, 98, 98, 99, 99, 100, 101, 101, 102, 102, 103, 103, 104, 104,
		105, 105, 106, 106, 107, 107, 108, 108, 108, 109, 109, 110, 110, 110, 111, 111,
		112, 112, 112, 113, 113, 113, 114, 114, 114, 115, 115, 115, 115, 116, 116, 116,
		117, 117, 117, 118, 118, 118, 118, 119, 119, 119, 119, 120, 120, 120, 120, 121,
		121, 121, 121, 122, 122, 122, 122, 122, 123, 123, 123, 123, 124, 124, 124, 124,
		124, 125, 125, 125, 125, 125, 126, 126, 126, 126, 126, 127, 127, 127, 127, 127,
		128, 128, 128, 128, 128, 128, 129, 129, 129, 129, 129, 129, 130, 130, 130, 130,
		130, 130, 131, 131, 131, 131, 131, 131, 131, 132, 132, 132, 132, 132, 132, 133,
		133, 133, 133, 133, 133, 133, 134, 134, 134, 134, 134, 134, 134, 134, 135, 135,
		135, 135, 135, 135, 135, 135, 136, 136, 136, 136, 136, 136, 136, 136, 137, 137,
		137, 137, 137, 137, 137, 137, 138, 138, 138, 138, 138, 138, 138, 138, 138, 139,
		139, 139, 139, 139, 139, 139, 139, 139, 140, 140, 140, 140, 140, 140, 140, 140,
		140, 141, 141, 141, 141, 141, 141, 141, 141, 141, 141, 142, 142, 142, 142, 142,
		142, 142, 142, 142, 142, 142, 143, 143, 143, 143, 143, 143, 143, 143, 143, 143,
		144
	]

	default_lit_cost_2 : List(U8)
	default_lit_cost_2 = [
		32, 32, 48, 57, 64, 69, 73, 76, 80, 82, 85, 87, 89, 91, 92, 94,
		96, 97, 98, 99, 101, 102, 103, 104, 105, 106, 107, 108, 108, 109, 110, 111,
		112, 112, 113, 114, 114, 115, 115, 116, 117, 117, 118, 118, 119, 119, 120, 120,
		121, 121, 122, 122, 123, 123, 124, 124, 124, 125, 125, 126, 126, 126, 127, 127,
		128, 128, 128, 129, 129, 129, 130, 130, 130, 131, 131, 131, 131, 132, 132, 132,
		133, 133, 133, 134, 134, 134, 134, 135, 135, 135, 135, 136, 136, 136, 136, 137,
		137, 137, 137, 138, 138, 138, 138, 138, 139, 139, 139, 139, 140, 140, 140, 140,
		140, 141, 141, 141, 141, 141, 142, 142, 142, 142, 142, 143, 143, 143, 143, 143,
		144, 144, 144, 144, 144, 144, 145, 145, 145, 145, 145, 145, 146, 146, 146, 146,
		146, 146, 147, 147, 147, 147, 147, 147, 147, 148, 148, 148, 148, 148, 148, 149,
		149, 149, 149, 149, 149, 149, 150, 150, 150, 150, 150, 150, 150, 150, 151, 151,
		151, 151, 151, 151, 151, 151, 152, 152, 152, 152, 152, 152, 152, 152, 153, 153,
		153, 153, 153, 153, 153, 153, 154, 154, 154, 154, 154, 154, 154, 154, 154, 155,
		155, 155, 155, 155, 155, 155, 155, 155, 156, 156, 156, 156, 156, 156, 156, 156,
		156, 157, 157, 157, 157, 157, 157, 157, 157, 157, 157, 158, 158, 158, 158, 158,
		158, 158, 158, 158, 158, 158, 159, 159, 159, 159, 159, 159, 159, 159, 159, 159,
		160
	]

	default_len_sym_costs : List(U8)
	default_len_sym_costs = [109, 93, 84]
	## Cost model for one block, all in sixteenths of a bit.
	Costs : { literal : List(U32), length : List(U32), offset_slot : List(U32) }

	## Take the cost model straight from a set of codeword lengths.
	set_costs_from_codes : List(U8), List(U8), List(U32), List(U32), List(U32) -> Try(Costs, [CompressBug])
	set_costs_from_codes = |litlen_lens, offset_lens, literal_0, length_0, offset_slot_0| {
		var $literal = literal_0
		var $length = length_0
		var $offset_slot = offset_slot_0

		var $i = 0.U64
		while $i < DeflateTables.num_literals {
			l = (List.get(litlen_lens, $i) ?? 0).to_u64()
			bits = if l != 0 { l } else { CompressOptimal.literal_nostat_bits }
			$literal = match List.set($literal, $i, (bits * CompressOptimal.bit_cost).to_u32_wrap()) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$i = $i + 1
		}

		$i = DeflateTables.min_match_len
		while $i <= DeflateTables.max_match_len {
			slot = DeflateTables.length_slot($i)
			sym = DeflateTables.first_len_sym + slot
			l = (List.get(litlen_lens, sym) ?? 0).to_u64()
			bits = if l != 0 { l } else { CompressOptimal.length_nostat_bits }
			total = bits + (List.get(DeflateTables.extra_length_bits, slot) ?? 0).to_u64()
			$length = match List.set($length, $i, (total * CompressOptimal.bit_cost).to_u32_wrap()) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$i = $i + 1
		}

		$i = 0
		while $i < DeflateTables.num_offset_syms {
			l = (List.get(offset_lens, $i) ?? 0).to_u64()
			bits = if l != 0 { l } else { CompressOptimal.offset_nostat_bits }
			total = bits + (List.get(DeflateTables.extra_offset_bits, $i) ?? 0).to_u64()
			$offset_slot = match List.set($offset_slot, $i, (total * CompressOptimal.bit_cost).to_u32_wrap()) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$i = $i + 1
		}

		Ok({ literal: $literal, length: $length, offset_slot: $offset_slot })
	}

	## Cost of a match length under the default model, where every length
	## symbol is assumed equally likely but its extra bits still have to be
	## paid for.
	default_length_cost : U64, U64 -> U64
	default_length_cost = |len, len_sym_cost| {
		slot = DeflateTables.length_slot(len)
		len_sym_cost + (List.get(DeflateTables.extra_length_bits, slot) ?? 0).to_u64() * CompressOptimal.bit_cost
	}

	default_offset_slot_cost : U64 -> U64
	default_offset_slot_cost = |slot|
		CompressOptimal.default_offset_sym_cost
			+ (List.get(DeflateTables.extra_offset_bits, slot) ?? 0).to_u64() * CompressOptimal.bit_cost

	## Set the model from the defaults alone, which is what the first block
	## does since there is no previous block to learn from.
	set_default_costs : U64, U64, List(U32), List(U32), List(U32) -> Try(Costs, [CompressBug])
	set_default_costs = |lit_cost, len_sym_cost, literal_0, length_0, offset_slot_0| {
		var $literal = literal_0
		var $length = length_0
		var $offset_slot = offset_slot_0

		var $i = 0.U64
		while $i < DeflateTables.num_literals {
			$literal = match List.set($literal, $i, lit_cost.to_u32_wrap()) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$i = $i + 1
		}
		$i = DeflateTables.min_match_len
		while $i <= DeflateTables.max_match_len {
			$length = match List.set($length, $i, CompressOptimal.default_length_cost($i, len_sym_cost).to_u32_wrap()) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$i = $i + 1
		}
		$i = 0
		while $i < DeflateTables.num_offset_syms {
			$offset_slot = match List.set($offset_slot, $i, CompressOptimal.default_offset_slot_cost($i).to_u32_wrap()) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$i = $i + 1
		}
		Ok({ literal: $literal, length: $length, offset_slot: $offset_slot })
	}

	## Blend one cost towards its default. The more the block differs from the
	## previous one, the more weight the default carries.
	adjust_cost : U32, U64, U64 -> U32
	adjust_cost = |cur, default_cost, change_amount| {
		c = cur.to_u64()
		if change_amount == 0 {
			((default_cost + 3 * c) // 4).to_u32_wrap()
		} else if change_amount == 1 {
			((default_cost + c) // 2).to_u32_wrap()
		} else if change_amount == 2 {
			((5 * default_cost + 3 * c) // 8).to_u32_wrap()
		} else {
			((3 * default_cost + c) // 4).to_u32_wrap()
		}
	}

	adjust_costs_impl : U64, U64, U64, List(U32), List(U32), List(U32) -> Try(Costs, [CompressBug])
	adjust_costs_impl = |lit_cost, len_sym_cost, change_amount, literal_0, length_0, offset_slot_0| {
		var $literal = literal_0
		var $length = length_0
		var $offset_slot = offset_slot_0

		var $i = 0.U64
		while $i < DeflateTables.num_literals {
			cur = List.get($literal, $i) ?? 0
			$literal = match List.set($literal, $i, CompressOptimal.adjust_cost(cur, lit_cost, change_amount)) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$i = $i + 1
		}
		$i = DeflateTables.min_match_len
		while $i <= DeflateTables.max_match_len {
			cur = List.get($length, $i) ?? 0
			d = CompressOptimal.default_length_cost($i, len_sym_cost)
			$length = match List.set($length, $i, CompressOptimal.adjust_cost(cur, d, change_amount)) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$i = $i + 1
		}
		$i = 0
		while $i < DeflateTables.num_offset_syms {
			cur = List.get($offset_slot, $i) ?? 0
			d = CompressOptimal.default_offset_slot_cost($i)
			$offset_slot = match List.set($offset_slot, $i, CompressOptimal.adjust_cost(cur, d, change_amount)) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$i = $i + 1
		}
		Ok({ literal: $literal, length: $length, offset_slot: $offset_slot })
	}

	## Guess the default literal and length-symbol costs for a block from the
	## data itself: how many distinct literals it uses, and how much of it a
	## greedy parse would have covered with matches.
	DefaultCosts : { lit_cost : U64, len_sym_cost : U64 }

	choose_default_litlen_costs : List(U8), U64, U64, List(U32), U64 -> Try(DefaultCosts, [CompressBug])
	choose_default_litlen_costs = |input, block_begin, block_length, match_len_freqs, max_search_depth| {
		var $counts = List.repeat(0.U32, DeflateTables.num_literals)
		# Literals that barely occur do not really widen the alphabet.
		cutoff = block_length.shr_zf_wrap(11)
		var $i = 0.U64
		while $i < block_length {
			b = (List.get(input, block_begin + $i) ?? 0).to_u64()
			b_count = (List.get($counts, b) ?? 0) + 1
			$counts = match List.set($counts, b, b_count) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$i = $i + 1
		}
		var $num_used_literals = 0.U64
		$i = 0
		while $i < DeflateTables.num_literals {
			if (List.get($counts, $i) ?? 0).to_u64() > cutoff {
				$num_used_literals = $num_used_literals + 1
			} else {
			}
			$i = $i + 1
		}
		if $num_used_literals == 0 {
			$num_used_literals = 1
		} else {
		}

		# The same minimum-match-length heuristic the greedy and lazy parsers
		# use, so that matches too short to be worth taking are not counted.
		var $match_freq = 0.I64
		var $literal_freq = block_length.to_i64_wrap()
		var $j = CompressLazy.choose_min_match_len($num_used_literals, max_search_depth)
		while $j <= DeflateTables.max_match_len {
			f = (List.get(match_len_freqs, $j) ?? 0).to_i64()
			$match_freq = $match_freq + f
			$literal_freq = $literal_freq - $j.to_i64_wrap() * f
			$j = $j + 1
		}
		if $literal_freq < 0 {
			$literal_freq = 0
		} else {
		}

		which =
			if $match_freq > $literal_freq {
				2
			} else if $match_freq * 4 > $literal_freq {
				1
			} else {
				0
			}
		table =
			if which == 2 {
				CompressOptimal.default_lit_cost_2
			} else if which == 1 {
				CompressOptimal.default_lit_cost_1
			} else {
				CompressOptimal.default_lit_cost_0
			}
		Ok({
			lit_cost: (List.get(table, $num_used_literals) ?? 0).to_u64(),
			len_sym_cost: (List.get(CompressOptimal.default_len_sym_costs, which) ?? 0).to_u64(),
		})
	}

	## The path a min-cost search chose: for each position, the item that
	## starts the cheapest way of finishing the block from there.
	PathResult : { node_cost : List(U32), node_item : List(U32) }

	## The symbols a path uses and the Huffman codes built for them.
	TallyResult : {
		freqs_litlen : List(U32),
		freqs_offset : List(U32),
		litlen_lens : List(U8),
		litlen_codewords : List(U32),
		offset_lens : List(U8),
		offset_codewords : List(U32),
	}

	## Find the cheapest sequence of literals and matches for the block under
	## the given cost model, and build the Huffman codes it implies.
	##
	## The search runs backwards from the end of the block, so that when a
	## position is reached the cost of finishing from every later position is
	## already known and choosing at this position is a single scan over its
	## cached matches. For each length only the nearest offset that reaches it
	## is considered, which is what makes that scan linear in the number of
	## matches rather than quadratic.
	find_min_cost_path : U64, List(U32), List(U32), U64, List(U32), List(U32), List(U32), List(U32), List(U32) -> Try(PathResult, [CompressBug])
	find_min_cost_path = |block_length, cache_len, cache_off, cache_end, node_cost_0, node_item_0, cost_literal, cost_length, cost_offset_slot| {
		var $node_cost = node_cost_0
		var $node_item = node_item_0

		$node_cost = match List.set($node_cost, block_length, 0) {
			Ok(next) => next
			Err(_) => return Err(CompressBug)
		}

		# Wrapping arithmetic on the per-node path: the cursor and the cache
		# pointer only step down while nonzero, a match never reaches past the
		# block, and a cost is a bit count bounded by the block length times the
		# longest codeword, so nothing here can overflow and a checked operation
		# would only put an overflow branch on every candidate length.
		var $cur = block_length
		var $cp = cache_end
		while $cur != 0 {
			$cur = $cur.minus_wrap(1)
			$cp = $cp.minus_wrap(1)
			num_matches = (List.get(cache_len, $cp) ?? 0).to_u64()
			literal = (List.get(cache_off, $cp) ?? 0).to_u64()

			# A literal is always available, so it seeds the comparison.
			var $best = (List.get(cost_literal, literal) ?? 0).plus_wrap(List.get($node_cost, $cur.plus_wrap(1)) ?? 0)
			var $item = literal.to_u32_wrap().shl_wrap(CompressOptimal.optimum_offset_shift).bitwise_or(1)

			if num_matches != 0 {
				var $m = $cp.minus_wrap(num_matches)
				var $len = DeflateTables.min_match_len
				while $m != $cp {
					offset = (List.get(cache_off, $m) ?? 0).to_u64()
					offset_cost = List.get(cost_offset_slot, DeflateTables.offset_slot(offset)) ?? 0
					this_len = (List.get(cache_len, $m) ?? 0).to_u64()
					while $len <= this_len {
						cost_to_end = offset_cost
							.plus_wrap(List.get(cost_length, $len) ?? 0)
							.plus_wrap(List.get($node_cost, $cur.plus_wrap($len)) ?? 0)
						if cost_to_end < $best {
							$best = cost_to_end
							$item = $len.to_u32_wrap()
								.bitwise_or(offset.to_u32_wrap().shl_wrap(CompressOptimal.optimum_offset_shift))
						} else {
						}
						$len = $len.plus_wrap(1)
					}
					$m = $m.plus_wrap(1)
				}
				$cp = $cp.minus_wrap(num_matches)
			} else {
			}

			$node_cost = match List.set($node_cost, $cur, $best) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$node_item = match List.set($node_item, $cur, $item) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
		}

		Ok({ node_cost: $node_cost, node_item: $node_item })
	}

	## Count the symbols a chosen path uses and build the Huffman codes for
	## them, walking the path forwards this time.
	tally_and_build_codes : List(U32), U64 -> Try(TallyResult, [CompressBug])
	tally_and_build_codes = |node_item, block_length| {
		var $freqs_litlen = List.repeat(0.U32, DeflateTables.num_litlen_syms)
		var $freqs_offset = List.repeat(0.U32, DeflateTables.num_offset_syms)
		var $at = 0.U64
		while $at != block_length {
			item = List.get(node_item, $at) ?? 0
			length = item.bitwise_and(CompressOptimal.optimum_len_mask).to_u64()
			offset = item.shr_zf_wrap(CompressOptimal.optimum_offset_shift).to_u64()
			if length == 1 {
				offset_count = (List.get($freqs_litlen, offset) ?? 0) + 1
				$freqs_litlen = match List.set($freqs_litlen, offset, offset_count) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
			} else {
				sym = DeflateTables.first_len_sym + DeflateTables.length_slot(length)
				sym_count = (List.get($freqs_litlen, sym) ?? 0) + 1
				$freqs_litlen = match List.set($freqs_litlen, sym, sym_count) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				slot = DeflateTables.offset_slot(offset)
				slot_count = (List.get($freqs_offset, slot) ?? 0) + 1
				$freqs_offset = match List.set($freqs_offset, slot, slot_count) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
			}
			$at = $at + length
		}
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

		Ok({
			freqs_litlen: $freqs_litlen,
			freqs_offset: $freqs_offset,
			litlen_lens: litlen_code.lens,
			litlen_codewords: litlen_code.codewords,
			offset_lens: offset_code.lens,
			offset_codewords: offset_code.codewords,
		})
	}

	LiteralChoice : {
		freqs_litlen : List(U32),
		freqs_offset : List(U32),
		litlen_lens : List(U8),
		litlen_codewords : List(U32),
		offset_lens : List(U8),
		offset_codewords : List(U32),
	}

	## Build the codes for the alternative in which the block is nothing but
	## literals, which on some data beats anything the optimizer finds.
	choose_all_literals : List(U8), U64, U64 -> Try(LiteralChoice, [CompressBug])
	choose_all_literals = |input, block_begin, block_length| {
		var $freqs_litlen = List.repeat(0.U32, DeflateTables.num_litlen_syms)
		freqs_offset = List.repeat(0.U32, DeflateTables.num_offset_syms)
		var $i = 0.U64
		while $i < block_length {
			b = (List.get(input, block_begin + $i) ?? 0).to_u64()
			b_count = (List.get($freqs_litlen, b) ?? 0) + 1
			$freqs_litlen = match List.set($freqs_litlen, b, b_count) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$i = $i + 1
		}
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
			freqs_offset,
			List.repeat(0.U8, DeflateTables.num_offset_syms),
			List.repeat(0.U32, DeflateTables.num_offset_syms),
		)?
		Ok({
			freqs_litlen: $freqs_litlen,
			freqs_offset: freqs_offset,
			litlen_lens: litlen_code.lens,
			litlen_codewords: litlen_code.codewords,
			offset_lens: offset_code.lens,
			offset_codewords: offset_code.codewords,
		})
	}

	## Exact cost in bits of writing the block as a dynamic Huffman block with
	## the given codes and symbol frequencies.
	##
	## This is what the optimizer's own cost model is only an approximation of,
	## so it is what the passes are compared on.
	compute_true_cost : List(U8), List(U8), List(U32), List(U32) -> Try(U64, [CompressBug])
	compute_true_cost = |litlen_lens, offset_lens, freqs_litlen, freqs_offset| {
		precode = BlockOut.precompute_huffman_header(litlen_lens, offset_lens)?

		var $cost = 5.U64 + 5 + 4 + 3 * precode.num_explicit_lens
		var $sym = 0.U64
		while $sym < DeflateTables.num_precode_syms {
			$cost = $cost
				+ (List.get(precode.freqs, $sym) ?? 0).to_u64()
					* ((List.get(precode.lens, $sym) ?? 0).to_u64()
						+ (List.get(DeflateTables.extra_precode_bits, $sym) ?? 0).to_u64())
			$sym = $sym + 1
		}

		$sym = 0
		while $sym < DeflateTables.first_len_sym {
			$cost = $cost
				+ (List.get(freqs_litlen, $sym) ?? 0).to_u64() * (List.get(litlen_lens, $sym) ?? 0).to_u64()
			$sym = $sym + 1
		}
		while $sym < DeflateTables.first_len_sym + 29 {
			extra = (List.get(DeflateTables.extra_length_bits, $sym - DeflateTables.first_len_sym) ?? 0).to_u64()
			$cost = $cost
				+ (List.get(freqs_litlen, $sym) ?? 0).to_u64()
					* ((List.get(litlen_lens, $sym) ?? 0).to_u64() + extra)
			$sym = $sym + 1
		}

		$sym = 0
		while $sym < DeflateTables.num_offset_syms {
			extra = (List.get(DeflateTables.extra_offset_bits, $sym) ?? 0).to_u64()
			$cost = $cost
				+ (List.get(freqs_offset, $sym) ?? 0).to_u64()
					* ((List.get(offset_lens, $sym) ?? 0).to_u64() + extra)
			$sym = $sym + 1
		}
		Ok($cost)
	}

	## Compress with the near-optimal parser.
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

		# The matchfinder tables and the two big per-block arrays are held as
		# separate values rather than in one record: a record of lists is
		# copied whenever it crosses a call boundary.
		var $tab3 = Matchfinder.init_nodes(BtMatchfinder.hash3_size)
		var $tab4 = Matchfinder.init_nodes(BtMatchfinder.hash4_size)
		var $child = Matchfinder.init_nodes(BtMatchfinder.child_size)
		var $nh3 = 0.U64
		var $nh4 = 0.U64

		var $cache_len = List.repeat(0.U32, CompressOptimal.match_cache_size)
		var $cache_off = List.repeat(0.U32, CompressOptimal.match_cache_size)
		var $cache_ptr = 0.U64
		var $node_cost = List.repeat(0.U32, CompressOptimal.optimum_nodes_size)
		var $node_item = List.repeat(0.U32, CompressOptimal.optimum_nodes_size)

		var $cost_literal = List.repeat(0.U32, DeflateTables.num_literals)
		var $cost_length = List.repeat(0.U32, DeflateTables.max_match_len + 1)
		var $cost_offset_slot = List.repeat(0.U32, DeflateTables.num_offset_syms)
		var $saved_literal = List.repeat(0.U32, DeflateTables.num_literals)
		var $saved_length = List.repeat(0.U32, DeflateTables.max_match_len + 1)
		var $saved_offset_slot = List.repeat(0.U32, DeflateTables.num_offset_syms)

		var $match_len_freqs = List.repeat(0.U32, DeflateTables.max_match_len + 1)
		var $new_match_len_freqs = List.repeat(0.U32, DeflateTables.max_match_len + 1)
		var $prev_observations = List.repeat(0.U32, CompressLazy.num_observation_types)
		var $prev_num_observations = 0.U64
		var $new_observations = List.repeat(0.U32, CompressLazy.num_observation_types)
		var $observations = List.repeat(0.U32, CompressLazy.num_observation_types)
		var $num_new_observations = 0.U64
		var $num_observations = 0.U64

		# The only-literals alternative needs a one-entry sequence list, which
		# says "this many literals, then the end of the block".
		var $seqs = List.repeat({ litrunlen_and_length: 0.U32, offset: 0.U16, offset_slot: 0.U16 }, 1)

		var $in_next = 0.U64
		var $in_block_begin = 0.U64
		var $in_cur_base = 0.U64
		var $in_next_slide = in_end.min(Matchfinder.window_size)
		var $max_len = DeflateTables.max_match_len
		var $nice_len = params.nice_match_length.min(DeflateTables.max_match_len)
		var $prev_block_used_only_literals = 0.U64

		var $blocking = 1.U64
		while $blocking == 1 {
			# Starting a new block.
			in_max_block_end = CompressLazy.choose_max_block_end(
				$in_block_begin,
				in_end,
				CompressLazy.soft_max_block_length,
			)
			var $prev_end_block_check = 0.U64
			var $have_prev_end_block_check = 0.U64
			var $change_detected = 0.U64
			var $next_observation = $in_next

			# The near-optimal parse does not itself respect a minimum match
			# length, since it can price short matches properly; the minimum is
			# only there to keep the block-splitting statistics honest. If the
			# previous block did best with no matches at all, the data is
			# probably more literal-heavy than the heuristic believes, so
			# gather literal statistics only.
			min_len =
				if $prev_block_used_only_literals == 1 {
					DeflateTables.max_match_len + 1
				} else {
					CompressLazy.calculate_min_match_len(
						input,
						$in_block_begin,
						in_max_block_end - $in_block_begin,
						params.max_search_depth,
					)?
				}

			var $in_block = 1.U64
			while $in_block == 1 {
				remaining = in_end.minus_wrap($in_next)

				if $in_next == $in_next_slide {
					$tab3 = Matchfinder.rebase_nodes($tab3)
					$tab4 = Matchfinder.rebase_nodes($tab4)
					$child = Matchfinder.rebase_nodes($child)
					$in_cur_base = $in_next
					$in_next_slide = $in_next.plus_wrap(remaining.min(Matchfinder.window_size))
				} else {
				}

				matches_at = $cache_ptr
				var $best_len = 0.U64
				if remaining < DeflateTables.max_match_len {
					$max_len = remaining
					$nice_len = $nice_len.min($max_len)
				} else {
				}
				if $max_len >= BtMatchfinder.required_nbytes {
					adv = BtMatchfinder.get_matches(
						$tab3,
						$tab4,
						$child,
						$nh3,
						$nh4,
						input,
						$in_cur_base,
						$in_next.minus_wrap($in_cur_base),
						$max_len,
						$nice_len,
						params.max_search_depth,
						$cache_len,
						$cache_off,
						$cache_ptr,
					)?
					$tab3 = adv.hash3
					$tab4 = adv.hash4
					$child = adv.child
					$nh3 = adv.next_hash3
					$nh4 = adv.next_hash4
					$cache_len = adv.cache_len
					$cache_off = adv.cache_off
					$cache_ptr = adv.cache_ptr
					if $cache_ptr > matches_at {
						$best_len = (List.get($cache_len, $cache_ptr.minus_wrap(1)) ?? 0).to_u64()
					} else {
					}
				} else {
				}

				# Statistics are sampled once per chosen item rather than once
				# per position, so a long match counts once and not for every
				# byte it covers.
				if $in_next >= $next_observation {
					if $best_len >= min_len {
						obs = 8 + if $best_len >= 9 { 1 } else { 0 }
						obs_count = (List.get($new_observations, obs) ?? 0).plus_wrap(1)
						$new_observations = match List.set($new_observations, obs, obs_count) {
							Ok(next) => next
							Err(_) => return Err(CompressBug)
						}
						$num_new_observations = $num_new_observations.plus_wrap(1)
						$next_observation = $in_next.plus_wrap($best_len)
						$new_match_len_freqs = match List.set($new_match_len_freqs, $best_len,
							(List.get($new_match_len_freqs, $best_len) ?? 0).plus_wrap(1)) {
							Ok(next) => next
							Err(_) => return Err(CompressBug)
						}
					} else {
						lit = (List.get(input, $in_next) ?? 0).to_u64()
						obs = lit.shr_zf_wrap(5).bitwise_and(0x6).bitwise_or(lit.bitwise_and(1))
						obs_count = (List.get($new_observations, obs) ?? 0).plus_wrap(1)
						$new_observations = match List.set($new_observations, obs, obs_count) {
							Ok(next) => next
							Err(_) => return Err(CompressBug)
						}
						$num_new_observations = $num_new_observations.plus_wrap(1)
						$next_observation = $in_next.plus_wrap(1)
					}
				} else {
				}

				# Close the position with a header giving how many matches were
				# written for it and the literal that starts there.
				$cache_len = match List.set($cache_len, $cache_ptr, $cache_ptr.minus_wrap(matches_at).to_u32_wrap()) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				$cache_off = match List.set($cache_off, $cache_ptr, (List.get(input, $in_next) ?? 0).to_u32()) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				$in_next = $in_next.plus_wrap(1)
				$cache_ptr = $cache_ptr.plus_wrap(1)

				# After a very long match, cache no matches for the bytes it
				# covers. Data with such matches is highly compressible anyway,
				# so little is lost, and it keeps highly redundant input from
				# filling the cache with matches nothing will choose.
				if $best_len >= DeflateTables.min_match_len and $best_len >= $nice_len {
					var $skip = $best_len.minus_wrap(1)
					while $skip != 0 {
						remaining2 = in_end.minus_wrap($in_next)
						if $in_next == $in_next_slide {
							$tab3 = Matchfinder.rebase_nodes($tab3)
							$tab4 = Matchfinder.rebase_nodes($tab4)
							$child = Matchfinder.rebase_nodes($child)
							$in_cur_base = $in_next
							$in_next_slide = $in_next.plus_wrap(remaining2.min(Matchfinder.window_size))
						} else {
						}
						if remaining2 < DeflateTables.max_match_len {
							$max_len = remaining2
							$nice_len = $nice_len.min($max_len)
						} else {
						}
						if $max_len >= BtMatchfinder.required_nbytes {
							sk = BtMatchfinder.skip_byte(
								$tab3,
								$tab4,
								$child,
								$nh3,
								$nh4,
								input,
								$in_cur_base,
								$in_next.minus_wrap($in_cur_base),
								$nice_len,
								params.max_search_depth,
							)?
							$tab3 = sk.hash3
							$tab4 = sk.hash4
							$child = sk.child
							$nh3 = sk.next_hash3
							$nh4 = sk.next_hash4
						} else {
						}
						$cache_len = match List.set($cache_len, $cache_ptr, 0) {
							Ok(next) => next
							Err(_) => return Err(CompressBug)
						}
						$cache_off = match List.set($cache_off, $cache_ptr, (List.get(input, $in_next) ?? 0).to_u32()) {
							Ok(next) => next
							Err(_) => return Err(CompressBug)
						}
						$in_next = $in_next.plus_wrap(1)
						$cache_ptr = $cache_ptr.plus_wrap(1)
						$skip = $skip.minus_wrap(1)
					}
				} else {
				}

				if $in_next >= in_max_block_end or $cache_ptr >= CompressOptimal.match_cache_length {
					$in_block = 0
				} else if $num_new_observations >= CompressLazy.observations_per_block_check
					and $in_next.minus_wrap($in_block_begin) >= CompressLazy.min_block_length
					and in_end.minus_wrap($in_next) >= CompressLazy.min_block_length {
					if CompressLazy.do_end_block_check($new_observations, $observations, $num_new_observations, $num_observations, $in_next.minus_wrap($in_block_begin)) == 1 {
						$change_detected = 1
						$in_block = 0
					} else {
						ms = CompressLazy.merge_observations($new_observations, $observations, $num_new_observations, $num_observations)?
						$new_observations = ms.new_observations
						$observations = ms.observations
						$num_new_observations = ms.num_new_observations
						$num_observations = ms.num_observations
						merged = CompressOptimal.merge_match_len_freqs($match_len_freqs, $new_match_len_freqs)?
						$match_len_freqs = merged.total
						$new_match_len_freqs = merged.fresh
						$prev_end_block_check = $in_next
						$have_prev_end_block_check = 1
					}
				} else {
				}
			}

			# Where the block actually ends, and where in the cache that is.
			var $block_end = $in_next
			var $is_final = if $in_next == in_end { 1.U64 } else { 0 }
			var $cache_end = $cache_ptr
			var $rewound = 0.U64
			if $change_detected == 1 and $have_prev_end_block_check == 1 {
				# The block is ending because a recent stretch of data differs
				# from the rest of it. Ending at the current position would put
				# that stretch in this block; there is time here to do better,
				# so rewind to just before it and carry the work already done
				# on those positions into the next block.
				$block_end = $prev_end_block_check
				$is_final = 0
				var $to_rewind = $in_next - $prev_end_block_check
				while $to_rewind != 0 {
					$cache_end = $cache_end - 1
					$cache_end = $cache_end - (List.get($cache_len, $cache_end) ?? 0).to_u64()
					$to_rewind = $to_rewind - 1
				}
				$rewound = $cache_ptr - $cache_end
			} else {
				merged = CompressOptimal.merge_match_len_freqs($match_len_freqs, $new_match_len_freqs)?
				$match_len_freqs = merged.total
				$new_match_len_freqs = merged.fresh
				ms = CompressLazy.merge_observations($new_observations, $observations, $num_new_observations, $num_observations)?
				$new_observations = ms.new_observations
				$observations = ms.observations
				$num_new_observations = ms.num_new_observations
				$num_observations = ms.num_observations
			}
			block_length = $block_end - $in_block_begin
			is_first = if $in_block_begin == 0 { 1.U64 } else { 0 }

			# Cost the all-literals alternative before anything else, since it
			# is the only one that does not depend on the cost model.
			lits = CompressOptimal.choose_all_literals(input, $in_block_begin, block_length)?
			only_lits_cost = CompressOptimal.compute_true_cost(
				lits.litlen_lens,
				lits.offset_lens,
				lits.freqs_litlen,
				lits.freqs_offset,
			)?

			# Make the block really end where it should, even though matches
			# found near the end may reach past it.
			var $stop = block_length
			stop_end = (block_length - 1 + DeflateTables.max_match_len).min(CompressOptimal.optimum_nodes_size - 1)
			while $stop <= stop_end {
				$node_cost = match List.set($node_cost, $stop, 0x80000000) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				$stop = $stop + 1
			}

			# A static Huffman block is sometimes cheapest, especially a short
			# one. When the block is short enough to be worth the time, find
			# the best path under the static codes and remember what it costs.
			var $static_cost = 0xFFFFFFFFFFFFFFFF.U64
			if block_length <= params.max_len_to_optimize_static_block {
				sc = CompressOptimal.set_costs_from_codes(
					$s_litlen_lens,
					$s_offset_lens,
					List.repeat(0.U32, DeflateTables.num_literals),
					List.repeat(0.U32, DeflateTables.max_match_len + 1),
					List.repeat(0.U32, DeflateTables.num_offset_syms),
				)?
				path = CompressOptimal.find_min_cost_path(
					block_length,
					$cache_len,
					$cache_off,
					$cache_end,
					$node_cost,
					$node_item,
					sc.literal,
					sc.length,
					sc.offset_slot,
				)?
				$node_cost = path.node_cost
				$node_item = path.node_item
				$static_cost = (List.get($node_cost, 0) ?? 0).to_u64() // CompressOptimal.bit_cost + 7
			} else {
			}

			# Set the model for the first pass. A block after the first starts
			# from the previous block's model, mixed towards the defaults by
			# how much the two blocks differ.
			defaults = CompressOptimal.choose_default_litlen_costs(
				input,
				$in_block_begin,
				block_length,
				$match_len_freqs,
				params.max_search_depth,
			)?
			initial =
				if is_first == 1 {
					CompressOptimal.set_default_costs(
						defaults.lit_cost,
						defaults.len_sym_cost,
						$cost_literal,
						$cost_length,
						$cost_offset_slot,
					)?
				} else {
					CompressOptimal.adjust_costs(
						defaults.lit_cost,
						defaults.len_sym_cost,
						$prev_observations,
						$prev_num_observations,
						$observations,
						$num_observations,
						$cost_literal,
						$cost_length,
						$cost_offset_slot,
					)?
				}
			$cost_literal = initial.literal
			$cost_length = initial.length
			$cost_offset_slot = initial.offset_slot

			var $freqs_litlen = List.repeat(0.U32, DeflateTables.num_litlen_syms)
			var $freqs_offset = List.repeat(0.U32, DeflateTables.num_offset_syms)
			var $litlen_lens = List.repeat(0.U8, DeflateTables.num_litlen_syms)
			var $litlen_codewords = List.repeat(0.U32, DeflateTables.num_litlen_syms)
			var $offset_lens = List.repeat(0.U8, DeflateTables.num_offset_syms)
			var $offset_codewords = List.repeat(0.U32, DeflateTables.num_offset_syms)

			var $best_true_cost = 0xFFFFFFFFFFFFFFFF.U64
			var $true_cost = 0.U64
			var $passes_remaining = params.max_optim_passes
			var $optimizing = 1.U64
			while $optimizing == 1 {
				path = CompressOptimal.find_min_cost_path(
					block_length,
					$cache_len,
					$cache_off,
					$cache_end,
					$node_cost,
					$node_item,
					$cost_literal,
					$cost_length,
					$cost_offset_slot,
				)?
				$node_cost = path.node_cost
				$node_item = path.node_item
				tallied = CompressOptimal.tally_and_build_codes($node_item, block_length)?
				$freqs_litlen = tallied.freqs_litlen
				$freqs_offset = tallied.freqs_offset
				$litlen_lens = tallied.litlen_lens
				$litlen_codewords = tallied.litlen_codewords
				$offset_lens = tallied.offset_lens
				$offset_codewords = tallied.offset_codewords

				# What the path would really cost with the codes it implies,
				# rather than with the model that produced it.
				$true_cost = CompressOptimal.compute_true_cost(
					$litlen_lens,
					$offset_lens,
					$freqs_litlen,
					$freqs_offset,
				)?

				if $true_cost + params.min_improvement_to_continue > $best_true_cost {
					# Barely an improvement, so further passes are unlikely to
					# find one either.
					$optimizing = 0
				} else {
					$best_true_cost = $true_cost
					$saved_literal = $cost_literal
					$saved_length = $cost_length
					$saved_offset_slot = $cost_offset_slot
					from_codes = CompressOptimal.set_costs_from_codes(
						$litlen_lens,
						$offset_lens,
						$cost_literal,
						$cost_length,
						$cost_offset_slot,
					)?
					$cost_literal = from_codes.literal
					$cost_length = from_codes.length
					$cost_offset_slot = from_codes.offset_slot
					$passes_remaining = $passes_remaining - 1
					if $passes_remaining == 0 {
						$optimizing = 0
					} else {
					}
				}
			}

			var $use_items = 1.U64
			var $used_only_literals = 0.U64
			if only_lits_cost.min($static_cost) < $best_true_cost {
				if only_lits_cost < $static_cost {
					relits = CompressOptimal.choose_all_literals(input, $in_block_begin, block_length)?
					$freqs_litlen = relits.freqs_litlen
					$freqs_offset = relits.freqs_offset
					$litlen_lens = relits.litlen_lens
					$litlen_codewords = relits.litlen_codewords
					$offset_lens = relits.offset_lens
					$offset_codewords = relits.offset_codewords
					from_codes = CompressOptimal.set_costs_from_codes(
						$litlen_lens,
						$offset_lens,
						$cost_literal,
						$cost_length,
						$cost_offset_slot,
					)?
					$cost_literal = from_codes.literal
					$cost_length = from_codes.length
					$cost_offset_slot = from_codes.offset_slot
					$seqs = match List.set($seqs, 0, {
						litrunlen_and_length: block_length.to_u32_wrap(),
						offset: 0.U16,
						offset_slot: 0.U16,
					}) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$use_items = 0
					$used_only_literals = 1
				} else {
					from_codes = CompressOptimal.set_costs_from_codes(
						$s_litlen_lens,
						$s_offset_lens,
						$cost_literal,
						$cost_length,
						$cost_offset_slot,
					)?
					$cost_literal = from_codes.literal
					$cost_length = from_codes.length
					$cost_offset_slot = from_codes.offset_slot
					path = CompressOptimal.find_min_cost_path(
						block_length,
						$cache_len,
						$cache_off,
						$cache_end,
						$node_cost,
						$node_item,
						$cost_literal,
						$cost_length,
						$cost_offset_slot,
					)?
					$node_cost = path.node_cost
					$node_item = path.node_item
					tallied = CompressOptimal.tally_and_build_codes($node_item, block_length)?
					$freqs_litlen = tallied.freqs_litlen
					$freqs_offset = tallied.freqs_offset
					$litlen_lens = tallied.litlen_lens
					$litlen_codewords = tallied.litlen_codewords
					$offset_lens = tallied.offset_lens
					$offset_codewords = tallied.offset_codewords
				}
			} else if $true_cost >= $best_true_cost + params.min_bits_to_use_nonfinal_path {
				# The last pass made things worse by enough to be worth going
				# back and regenerating the path an earlier pass found.
				$cost_literal = $saved_literal
				$cost_length = $saved_length
				$cost_offset_slot = $saved_offset_slot
				path = CompressOptimal.find_min_cost_path(
					block_length,
					$cache_len,
					$cache_off,
					$cache_end,
					$node_cost,
					$node_item,
					$cost_literal,
					$cost_length,
					$cost_offset_slot,
				)?
				$node_cost = path.node_cost
				$node_item = path.node_item
				tallied = CompressOptimal.tally_and_build_codes($node_item, block_length)?
				$freqs_litlen = tallied.freqs_litlen
				$freqs_offset = tallied.freqs_offset
				$litlen_lens = tallied.litlen_lens
				$litlen_codewords = tallied.litlen_codewords
				$offset_lens = tallied.offset_lens
				$offset_codewords = tallied.offset_codewords
				from_codes = CompressOptimal.set_costs_from_codes(
					$litlen_lens,
					$offset_lens,
					$cost_literal,
					$cost_length,
					$cost_offset_slot,
				)?
				$cost_literal = from_codes.literal
				$cost_length = from_codes.length
				$cost_offset_slot = from_codes.offset_slot
			} else {
			}

			flushed = BlockOut.flush_block(
				$out,
				$bitbuf,
				$bitcount,
				input,
				$in_block_begin,
				block_length,
				$seqs,
				$freqs_litlen,
				$freqs_offset,
				$litlen_lens,
				$litlen_codewords,
				$offset_lens,
				$offset_codewords,
				$s_litlen_lens,
				$s_litlen_codewords,
				$s_offset_lens,
				$s_offset_codewords,
				$node_item,
				$use_items,
				$is_final,
			)?
			$out = flushed.out
			$bitbuf = flushed.bitbuf
			$bitcount = flushed.bitcount
			$seqs = flushed.seqs
			$node_item = flushed.items
			$s_litlen_lens = flushed.static_litlen_lens
			$s_litlen_codewords = flushed.static_litlen_codewords
			$s_offset_lens = flushed.static_offset_lens
			$s_offset_codewords = flushed.static_offset_codewords
			$prev_block_used_only_literals = $used_only_literals

			# Carry the statistics into the next block: what this block saw
			# becomes what the next block compares itself against.
			$prev_observations = $observations
			$prev_num_observations = $num_observations

			if $change_detected == 1 and $have_prev_end_block_check == 1 {
				# Move the positions that were rewound back to the front of the
				# cache, since they belong to the block now starting.
				var $k = 0.U64
				while $k < $rewound {
					v_len = List.get($cache_len, $cache_end + $k) ?? 0
					$cache_len = match List.set($cache_len, $k, v_len) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					v_off = List.get($cache_off, $cache_end + $k) ?? 0
					$cache_off = match List.set($cache_off, $k, v_off) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$k = $k + 1
				}
				$cache_ptr = $rewound
				# Clear the statistics for the block just flushed, keeping the
				# ones already gathered for the block now starting.
				$observations = List.repeat(0.U32, CompressLazy.num_observation_types)
				$num_observations = 0
				$match_len_freqs = List.repeat(0.U32, DeflateTables.max_match_len + 1)
				$in_block_begin = $block_end
			} else {
				$cache_ptr = 0
				$new_observations = List.repeat(0.U32, CompressLazy.num_observation_types)
				$observations = List.repeat(0.U32, CompressLazy.num_observation_types)
				$num_new_observations = 0
				$num_observations = 0
				$new_match_len_freqs = List.repeat(0.U32, DeflateTables.max_match_len + 1)
				$match_len_freqs = List.repeat(0.U32, DeflateTables.max_match_len + 1)
				$in_block_begin = $in_next
			}

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

	MergedFreqs : { total : List(U32), fresh : List(U32) }

	## Fold the match lengths seen since the last check into the block's
	## running totals.
	merge_match_len_freqs : List(U32), List(U32) -> Try(MergedFreqs, [CompressBug])
	merge_match_len_freqs = |total_0, fresh_0| {
		var $total = total_0
		var $fresh = fresh_0
		var $i = 0.U64
		while $i <= DeflateTables.max_match_len {
			f = List.get($fresh, $i) ?? 0
			if f != 0 {
				total_count = (List.get($total, $i) ?? 0) + f
				$total = match List.set($total, $i, total_count) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				$fresh = match List.set($fresh, $i, 0) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
			} else {
			}
			$i = $i + 1
		}
		Ok({ total: $total, fresh: $fresh })
	}

	## Mix the previous block's model with the defaults according to how alike
	## the two blocks look.
	##
	## The comparison is the same sum-of-absolute-differences test the
	## block-splitter uses, but between two whole blocks rather than a block
	## and a small tail of it.
	adjust_costs : U64, U64, List(U32), U64, List(U32), U64, List(U32), List(U32), List(U32) -> Try(Costs, [CompressBug])
	adjust_costs = |lit_cost, len_sym_cost, prev_observations, prev_num_observations, observations, num_observations, literal_0, length_0, offset_slot_0| {
		var $total_delta = 0.U64
		var $i = 0.U64
		while $i < CompressLazy.num_observation_types {
			prev = (List.get(prev_observations, $i) ?? 0).to_u64() * num_observations
			cur = (List.get(observations, $i) ?? 0).to_u64() * prev_num_observations
			$total_delta = $total_delta + if prev > cur { prev - cur } else { cur - prev }
			$i = $i + 1
		}
		cutoff = prev_num_observations * num_observations * 200 // 512

		if $total_delta > 3 * cutoff {
			CompressOptimal.set_default_costs(lit_cost, len_sym_cost, literal_0, length_0, offset_slot_0)
		} else if 4 * $total_delta > 9 * cutoff {
			CompressOptimal.adjust_costs_impl(lit_cost, len_sym_cost, 3, literal_0, length_0, offset_slot_0)
		} else if 2 * $total_delta > 3 * cutoff {
			CompressOptimal.adjust_costs_impl(lit_cost, len_sym_cost, 2, literal_0, length_0, offset_slot_0)
		} else if 2 * $total_delta > cutoff {
			CompressOptimal.adjust_costs_impl(lit_cost, len_sym_cost, 1, literal_0, length_0, offset_slot_0)
		} else {
			CompressOptimal.adjust_costs_impl(lit_cost, len_sym_cost, 0, literal_0, length_0, offset_slot_0)
		}
	}
}
