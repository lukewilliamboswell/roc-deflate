import Matchfinder

## The hash-table matchfinder, ported from libdeflate's `ht_matchfinder.h`.
##
## Positions are stored biased by the window size, as the hash-chain
## matchfinder stores them (see `Matchfinder.node_bias`): the in-window test
## is one unsigned comparison against the current position, and a candidate's
## index is a wrapping add, so no entry needs sign-extending.
##
## Where the hash-chains matchfinder walks a chain, this keeps a fixed two
## entries per hash bucket and looks at both, which bounds the work per
## position without needing a depth counter. Only length-4 and longer matches
## are found, since a bucket that small cannot afford to spend an entry on
## length-3 candidates.
HtMatchfinder := [].{

	hash_order : U64
	hash_order = 15

	bucket_size : U64
	bucket_size = 2

	## Shortest match this matchfinder reports.
	min_match_len : U64
	min_match_len = 4

	## Bytes that must be readable at the search position: four for the
	## sequence itself and one more for the next position's hash.
	required_nbytes : U64
	required_nbytes = 5

	## Two entries per bucket, one bucket per hash value.
	table_size : U64
	table_size = 65536

	## The two entries of each bucket sit next to each other, so a bucket is
	## one cache line's worth of adjacent slots rather than two strided reads.
	##
	## The table is passed separately from the scalars rather than inside a
	## record: a record holding a list is copied when it crosses a call
	## boundary, which for a table this size costs far more than the search.
	State : { hash_tab : List(U16), in_cur_base : U64, next_hash : U64 }

	Match : { hash_tab : List(U16), in_cur_base : U64, next_hash : U64, length : U64, offset : U64 }

	## Find the longest match at `in_next`, considering the two candidates in
	## the position's hash bucket.
	##
	## The first entry is replaced by the current position and pushed down to
	## the second, so the bucket always holds the two most recent positions
	## with this hash. The copy happens even when the first candidate already
	## reaches `nice_len`, which costs nothing and keeps the store off the
	## branch.
	longest_match : List(U16), U64, U64, List(U8), U64, U64, U64 -> Try(Match, [CompressBug])
	longest_match = |tab_0, base_0, hash_0, input, in_next, max_len, nice_len| {
		if List.len(input) < 4 {
			return Err(CompressBug)
		} else {
		}
		var $tab = tab_0
		var $base = base_0
		if in_next.minus_wrap($base) == Matchfinder.window_size {
			$tab = Matchfinder.rebase_nodes($tab)
			$base = $base.plus_wrap(Matchfinder.window_size)
		} else {
		}
		in_base = $base
		# A node at or below the current position, in the biased space the
		# tables use, is out of the window.
		cur_pos = in_next.minus_wrap(in_base)

		hash = hash_0
		next_hash = Matchfinder.lz_hash(U32.from_le_bytes(input, in_next.plus_wrap(1)) ?? 0, HtMatchfinder.hash_order)
		seq = U32.from_le_bytes(input, in_next) ?? 0

		slot0 = hash.bitwise_and(0x7FFF).times_wrap(2)
		if slot0.plus_wrap(1) >= List.len($tab) {
			return Err(CompressBug)
		} else {
		}
		cur_node0 = List.get($tab, slot0) ?? 0
		tab1 = match List.set($tab, slot0, cur_pos.plus_wrap(Matchfinder.node_bias).to_u16_wrap()) {
			Ok(next) => next
			Err(_) => return Err(CompressBug)
		}

		var $best_len = 0.U64
		var $best_match_at = in_next

		if cur_node0.to_u64() <= cur_pos {
			Ok({ hash_tab: tab1, in_cur_base: in_base, next_hash, length: 0, offset: 0 })
		} else {
			match0_at = Matchfinder.node_index(in_base, cur_node0)

			# Push the displaced entry into the second slot.
			cur_node1 = List.get(tab1, slot0.plus_wrap(1)) ?? 0
			var $tab2 = match List.set(tab1, slot0.plus_wrap(1), cur_node0) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}

			if (U32.from_le_bytes(input, match0_at) ?? 0) == seq {
				$best_len = Matchfinder.lz_extend(input, in_next, match0_at, 4, max_len)
				$best_match_at = match0_at
				if cur_node1.to_u64() <= cur_pos or $best_len >= nice_len {
				} else {
					match1_at = Matchfinder.node_index(in_base, cur_node1)
					if (U32.from_le_bytes(input, match1_at) ?? 0) == seq
						and (U32.from_le_bytes(input, match1_at.plus_wrap($best_len).minus_wrap(3)) ?? 0)
							== (U32.from_le_bytes(input, in_next.plus_wrap($best_len).minus_wrap(3)) ?? 0) {
						len = Matchfinder.lz_extend(input, in_next, match1_at, 4, max_len)
						if len > $best_len {
							$best_len = len
							$best_match_at = match1_at
						} else {
						}
					} else {
					}
				}
			} else {
				if cur_node1.to_u64() <= cur_pos {
				} else {
					match1_at = Matchfinder.node_index(in_base, cur_node1)
					if (U32.from_le_bytes(input, match1_at) ?? 0) == seq {
						$best_len = Matchfinder.lz_extend(input, in_next, match1_at, 4, max_len)
						$best_match_at = match1_at
					} else {
					}
				}
			}

			Ok({
				hash_tab: $tab2,
				in_cur_base: in_base,
				next_hash,
				length: $best_len,
				offset: in_next.minus_wrap($best_match_at),
			})
		}
	}

	## Insert `count` positions into the buckets without searching them.
	skip_bytes : List(U16), U64, U64, List(U8), U64, U64, U64 -> Try(State, [CompressBug])
	skip_bytes = |tab_0, base_0, hash_0, input, in_next0, in_end, count| {
		# The run ends at `end`, and every hash read the loop makes lies within
		# `required_nbytes` of it. Bounding the run against the input's length
		# here, and the bucket table's size once after any slide, lets the
		# range prover discharge the bounds test on every read and bucket
		# access in the loop, so each byte pays only for the work itself.
		end = in_next0.plus_wrap(count)
		if end.plus_wrap(HtMatchfinder.required_nbytes) > in_end {
			Ok({ hash_tab: tab_0, in_cur_base: base_0, next_hash: hash_0 })
		} else if in_end > List.len(input) {
			Err(CompressBug)
		} else {
			var $tab = tab_0
			var $base = base_0
			var $in_next = in_next0
			var $cur_pos = $in_next.minus_wrap(base_0).to_i64_wrap()
			# One slide covers the whole run, since it is bounded by a window.
			if $cur_pos.plus_wrap(count.to_i64_wrap()).minus_wrap(1) >= Matchfinder.window_size.to_i64_wrap() {
				$tab = Matchfinder.rebase_nodes($tab)
				$base = $base.plus_wrap(Matchfinder.window_size)
				$cur_pos = $cur_pos.minus_wrap(Matchfinder.window_size.to_i64_wrap())
			} else {
			}
			if List.len($tab) < HtMatchfinder.table_size {
				return Err(CompressBug)
			} else {
			}

			# Wrapping arithmetic: the run was bounded against the input above and
			# a bucket index is a masked hash doubled, so nothing here can overflow
			# and a checked add would only cost a branch per byte.
			var $hash = hash_0
			while $in_next < end {
				slot0 = $hash.bitwise_and(0x7FFF).times_wrap(2)
				first = List.get($tab, slot0) ?? 0
				tab1 = match List.set($tab, slot0.plus_wrap(1), first) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				$tab = match List.set(tab1, slot0, $cur_pos.plus_wrap(Matchfinder.node_bias.to_i64_wrap()).to_u16_wrap()) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}

				$in_next = $in_next.plus_wrap(1)
				$hash = Matchfinder.lz_hash(U32.from_le_bytes(input, $in_next) ?? 0, HtMatchfinder.hash_order)
				$cur_pos = $cur_pos.plus_wrap(1)
			}
			Ok({ hash_tab: $tab, in_cur_base: $base, next_hash: $hash })
		}
	}
}
