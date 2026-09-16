import Matchfinder

## The hash-chains matchfinder, ported from libdeflate's `hc_matchfinder.h`.
##
## Every position is inserted into a length-3 hash bucket and onto the front of
## a length-4 hash chain. A search walks the length-4 chain newest first, so it
## can stop after `max_search_depth` candidates and still have considered the
## nearest ones, which are the cheapest to encode.
##
## Two details carry most of the speed and are kept exactly:
##
##   - the walk rejects a candidate on four bytes at a time, and once a match
##     is established it first re-checks the four bytes ending just past the
##     current best length, so a candidate that cannot beat the incumbent is
##     discarded without extending it
##   - the first search and the "already have a length-4 match" search are
##     separate loops rather than one general loop, because each is tuned for
##     what it knows
HcMatchfinder := [].{

	hash3_order : U64
	hash3_order = 15

	hash4_order : U64
	hash4_order = 16

	hash3_size : U64
	hash3_size = 32768

	hash4_size : U64
	hash4_size = 65536

	## The three tables live in one list: the chain links first (one window
	## long, indexed by position), then the length-3 heads, then the length-4
	## heads. One list crosses each call and each loop as three words of
	## live state instead of nine, and is retained and released once.
	next_base : U64
	next_base = 0

	hash3_base : U64
	hash3_base = 32768

	hash4_base : U64
	hash4_base = 65536

	table_size : U64
	table_size = 131072

	State : {
		tab : List(U16),
		in_cur_base : U64,
		next_hash3 : U64,
		next_hash4 : U64,
	}

	Match : { length : U64, offset : U64 }

	init_tables : {} -> List(U16)
	init_tables = |{}|
		Matchfinder.init_nodes(HcMatchfinder.table_size)

	## Find the longest match at `in_next` that beats `best_len`, considering at
	## most `max_search_depth` candidates and stopping early at `nice_len`.
	## Find the longest match at `in_next`, walking the length-4 chain that
	## starts at `cur_node4` and trying the length-3 candidate `cur_node3`.
	##
	## This only reads the tables. The caller has already slid them if the
	## window moved, inserted the current position (which is why it holds the
	## two chain heads from before that insert), and computed the next hashes,
	## so the tables never cross this call as owned values: three large lists
	## handed back in a record would cost a retain and a release apiece on every
	## position, and this is the innermost per-position call.
	longest_match : List(U16), U16, U16, U64, List(U8), U64, U64, U64, U64, U64 -> Try(Match, [CompressBug])
	longest_match = |tab, cur_node3, cur_node4, in_base, input, in_next, best_len_in, max_len, nice_len, max_search_depth| {
		if List.len(input) < 4 {
			return Err(CompressBug)
		} else {
		}
		# The chain region is one window long, so every masked chain index is
		# in range, and a length guard here would let each chain read's bounds
		# test fold away. It is deliberately absent: the test costs nothing on
		# the walk's critical path, while its survival keeps the masked index
		# as a separate value that the load then scales for free. Folded, the
		# mask and scale merge into one instruction ahead of the load, which
		# is a cycle more on every step of the chain.
		# A node at or below the current position, in the biased space the
		# tables use, is out of the window.
		cur_pos = in_next.minus_wrap(in_base)

		var $best_len = best_len_in
		var $best_match_at = in_next

		seq4 = U32.from_le_bytes(input, in_next) ?? 0
		var $node4 = cur_node4
		var $depth = max_search_depth
		var $done = 0.U64

		if $best_len < 4 {
			if cur_node3.to_u64() <= cur_pos {
				$done = 1
			} else {
				if $best_len < 3 {
					match_at = Matchfinder.node_index(in_base, cur_node3)
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
						match_at = Matchfinder.node_index(in_base, $node4)
						if (U32.from_le_bytes(input, match_at) ?? 0) == seq4 {
							$found_at = match_at
							break
						} else {
						}
						$node4 = List.get(tab, $node4.to_u64().bitwise_and(32767)) ?? 0
						$depth = $depth.minus_wrap(1)
						if $node4.to_u64() <= cur_pos or $depth == 0 {
							$done = 1
							break
						} else {
						}
					}

					if $done == 0 {
						$best_match_at = $found_at
						$best_len = Matchfinder.lz_extend(input, in_next, $found_at, 4, max_len)
						if $best_len >= nice_len {
							$done = 1
						} else {
							$node4 = List.get(tab, $node4.to_u64().bitwise_and(32767)) ?? 0
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
			if $node4.to_u64() <= cur_pos or $best_len >= nice_len {
				$done = 1
			} else {
			}
		}

		# Now look only for matches longer than the one in hand.
		while $done == 0 {
			var $cand_at = 0.U64
			while True {
				match_at = Matchfinder.node_index(in_base, $node4)
				# The four bytes ending just past the current best length
				# are what a longer match must agree on, so check them
				# before anything else.
				# Wrapping arithmetic: positions are far below 2^63, and a checked
				# add or subtract would put an overflow branch on every candidate.
				if (U32.from_le_bytes(input, match_at.plus_wrap($best_len).minus_wrap(3)) ?? 0)
					== (U32.from_le_bytes(input, in_next.plus_wrap($best_len).minus_wrap(3)) ?? 0)
					and (U32.from_le_bytes(input, match_at) ?? 0) == seq4 {
					$cand_at = match_at
					break
				} else {
				}
				$node4 = List.get(tab, $node4.to_u64().bitwise_and(32767)) ?? 0
				$depth = $depth.minus_wrap(1)
				if $node4.to_u64() <= cur_pos or $depth == 0 {
					$done = 1
					break
				} else {
				}
			}

			if $done == 0 {
				len = Matchfinder.lz_extend(input, in_next, $cand_at, 4, max_len)
				if len > $best_len {
					$best_len = len
					$best_match_at = $cand_at
					if $best_len >= nice_len {
						$done = 1
					} else {
					}
				} else {
				}
				if $done == 0 {
					$node4 = List.get(tab, $node4.to_u64().bitwise_and(32767)) ?? 0
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

		Ok({ length: $best_len, offset: in_next.minus_wrap($best_match_at) })
	}

	## Insert `count` positions into the tables without searching them.
	skip_bytes : List(U16), U64, U64, U64, List(U8), U64, U64, U64 -> Try(State, [CompressBug])
	skip_bytes = |tab_0, base_0, nh3_0, nh4_0, input, in_next0, in_end, count| {
		if count.plus_wrap(5) > in_end.minus_wrap(in_next0) {
			Ok({
				tab: tab_0,
				in_cur_base: base_0,
				next_hash3: nh3_0,
				next_hash4: nh4_0,
			})
		} else {
			var $tab = tab_0
			var $base = base_0
			var $cur_pos = in_next0.minus_wrap(base_0).to_i64_wrap()
			# One slide covers the whole run, since a match is far shorter than
			# a window; positions past the slide go in already relative to the
			# new base.
			if $cur_pos.plus_wrap(count.to_i64_wrap()).minus_wrap(1) >= Matchfinder.window_size.to_i64_wrap() {
				$tab = Matchfinder.rebase_nodes($tab)
				$base = $base.plus_wrap(Matchfinder.window_size)
				$cur_pos = $cur_pos.minus_wrap(Matchfinder.window_size.to_i64_wrap())
			} else {
			}
			# The table holds all three regions, and the incoming hashes are
			# already reduced to their region's size. Establishing both once
			# here lets the bounds test on every table access in the loop fold
			# away instead of running per byte.
			if List.len($tab) < HcMatchfinder.table_size
				or nh3_0 >= HcMatchfinder.hash3_size
				or nh4_0 >= HcMatchfinder.hash4_size {
				return Err(CompressBug)
			} else {
			}
			# Wrapping arithmetic: the run was bounded against the input above and
			# the table indices are a region base plus a reduced hash, so nothing
			# here can overflow and a checked add would only cost a branch per byte.
			var $in_next = in_next0
			var $hash3 = nh3_0
			var $hash4 = nh4_0
			var $remaining = count
			while $remaining > 0 {
				pos = $cur_pos.plus_wrap(Matchfinder.node_bias.to_i64_wrap()).to_u16_wrap()
				slot = $cur_pos.to_u64_wrap().bitwise_and(32767)
				prev_head = List.get($tab, HcMatchfinder.hash4_base.plus_wrap($hash4)) ?? 0
				tab1 = match List.set($tab, HcMatchfinder.hash3_base.plus_wrap($hash3), pos) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				tab2 = match List.set(tab1, slot, prev_head) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				$tab = match List.set(tab2, HcMatchfinder.hash4_base.plus_wrap($hash4), pos) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				$in_next = $in_next.plus_wrap(1)
				next_hashseq = U32.from_le_bytes(input, $in_next) ?? 0
				$hash3 = Matchfinder.lz_hash(next_hashseq.bitwise_and(0xFFFFFF), HcMatchfinder.hash3_order)
				$hash4 = Matchfinder.lz_hash(next_hashseq, HcMatchfinder.hash4_order)
				$cur_pos = $cur_pos.plus_wrap(1)
				$remaining = $remaining.minus_wrap(1)
			}
			Ok({
				tab: $tab,
				in_cur_base: $base,
				next_hash3: $hash3,
				next_hash4: $hash4,
			})
		}
	}
}
