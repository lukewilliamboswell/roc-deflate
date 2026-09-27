import Matchfinder

## The binary-tree matchfinder, ported from libdeflate's `bt_matchfinder.h`.
##
## Where the other matchfinders report only the longest match, this reports
## every match worth considering at a position, in increasing length order,
## which is what the near-optimal parser needs to choose between them.
##
## Each position roots a binary search tree of the positions sharing its
## length-4 hash, ordered by the bytes that follow. Walking the tree both
## narrows the search and rebuilds it: the nodes passed on the way down are
## re-linked into the two pending subtrees, so the tree stays sorted against
## the data rather than needing a separate rebuild.
##
## Searching and skipping are two functions rather than one with a flag, since
## libdeflate compiles the shared body twice on a compile-time constant and the
## skipping copy has no reason to carry the recording branches.
BtMatchfinder := [].{

	hash3_order : U64
	hash3_order = 16

	hash3_ways : U64
	hash3_ways = 2

	hash4_order : U64
	hash4_order = 16

	## Entries in the two hash tables and in the child table. Every position in
	## the window has a left and a right child, hence the doubling.
	hash3_size : U64
	hash3_size = 65536 * BtMatchfinder.hash3_ways

	hash4_size : U64
	hash4_size = 65536

	child_size : U64
	child_size = 2 * Matchfinder.window_size

	## Bytes that must be readable at the position: four for the sequence and
	## one more for the next position's hash.
	required_nbytes : U64
	required_nbytes = 5

	## What a skip leaves behind: the tables and the hashes for the next
	## position, which the caller carries forward.
	State : {
		hash3 : List(U16),
		hash4 : List(U16),
		child : List(U16),
		next_hash3 : U64,
		next_hash4 : U64,
	}

	## A search additionally hands back the match cache it wrote into.
	Advanced : {
		hash3 : List(U16),
		hash4 : List(U16),
		child : List(U16),
		next_hash3 : U64,
		next_hash4 : U64,
		cache_len : List(U32),
		cache_off : List(U32),
		cache_ptr : U64,
	}

	## Advance one byte, writing every match found at this position into the
	## cache in strictly increasing length order.
	##
	## The tables travel as separate arguments rather than inside one record,
	## since a record holding a list is copied when it crosses a call boundary
	## and these tables are far larger than the search itself.
	get_matches : List(U16), List(U16), List(U16), U64, U64, List(U8), U64, U64, U64, U64, U64, List(U32), List(U32), U64 -> Try(Advanced, [CompressBug])
	get_matches = |tab3_0, tab4_0, child_0, nh3, nh4, input, in_base, cur_pos, max_len, nice_len, max_search_depth, cache_len_0, cache_off_0, cache_ptr_0| {
		# Wrapping index arithmetic throughout the search and the skip: every
		# position touched lies in the window the caller bounded against the
		# input, a child slot is a masked node doubled, and each read's own
		# bounds test rejects anything that wrapped, so a checked add would only
		# put an overflow branch ahead of every step of the tree walk.
		var $tab3 = tab3_0
		var $tab4 = tab4_0
		var $child = child_0
		var $cache_len = cache_len_0
		var $cache_off = cache_off_0
		var $cache_ptr = cache_ptr_0

		in_next = in_base.plus_wrap(cur_pos)
				next_hashseq = U32.from_le_bytes(input, in_next.plus_wrap(1)) ?? 0
		hash3 = nh3
		hash4 = nh4
		out_hash3 = Matchfinder.lz_hash(next_hashseq.bitwise_and(0xFFFFFF), BtMatchfinder.hash3_order)
		out_hash4 = Matchfinder.lz_hash(next_hashseq, BtMatchfinder.hash4_order)
		pos = cur_pos.plus_wrap(Matchfinder.node_bias).to_u16_wrap()

		# The length-3 hash keeps two ways, so a short match survives one
		# eviction. Its matches are reported but never entered into a tree.
		slot3 = hash3.times_wrap(2)
		node3 = List.get($tab3, slot3) ?? 0
		node3_2 = List.get($tab3, slot3.plus_wrap(1)) ?? 0
		$tab3 = match List.set($tab3, slot3, pos) {
			Ok(next) => next
			Err(_) => return Err(CompressBug)
		}
		$tab3 = match List.set($tab3, slot3.plus_wrap(1), node3) {
			Ok(next) => next
			Err(_) => return Err(CompressBug)
		}

		if node3.to_u64() > cur_pos {
			seq3 = (U32.from_le_bytes(input, in_next) ?? 0).bitwise_and(0xFFFFFF)
			at3 = Matchfinder.node_index(in_base, node3)
			if seq3 == (U32.from_le_bytes(input, at3) ?? 0).bitwise_and(0xFFFFFF) {
				$cache_len = match List.set($cache_len, $cache_ptr, 3) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				$cache_off = match List.set($cache_off, $cache_ptr, in_next.minus_wrap(at3).to_u32_wrap()) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				$cache_ptr = $cache_ptr.plus_wrap(1)
			} else if node3_2.to_u64() > cur_pos {
				at3b = Matchfinder.node_index(in_base, node3_2)
				if seq3 == (U32.from_le_bytes(input, at3b) ?? 0).bitwise_and(0xFFFFFF) {
					$cache_len = match List.set($cache_len, $cache_ptr, 3) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$cache_off = match List.set($cache_off, $cache_ptr, in_next.minus_wrap(at3b).to_u32_wrap()) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$cache_ptr = $cache_ptr.plus_wrap(1)
				} else {
				}
			} else {
			}
		} else {
		}

		node4 = List.get($tab4, hash4) ?? 0
		$tab4 = match List.set($tab4, hash4, pos) {
			Ok(next) => next
			Err(_) => return Err(CompressBug)
		}

		# The two subtrees being rebuilt hang off this position's child slots.
		var $pending_lt = cur_pos.bitwise_and(32767).times_wrap(2)
		var $pending_gt = $pending_lt.plus_wrap(1)

		if node4.to_u64() <= cur_pos {
			$child = match List.set($child, $pending_lt, 0) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$child = match List.set($child, $pending_gt, 0) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			return Ok({
				hash3: $tab3,
				hash4: $tab4,
				child: $child,
				next_hash3: out_hash3,
				next_hash4: out_hash4,
				cache_len: $cache_len,
				cache_off: $cache_off,
				cache_ptr: $cache_ptr,
			})
		} else {
		}

		var $node = node4
		var $depth = max_search_depth
		var $best_lt_len = 0.U64
		var $best_gt_len = 0.U64
		var $len = 0.U64
		var $best_len = 3.U64
		var $walking = 1.U64

		while $walking == 1 {
			match_at = Matchfinder.node_index(in_base, $node)

			if (List.get(input, match_at.plus_wrap($len)) ?? 0) == (List.get(input, in_next.plus_wrap($len)) ?? 0) {
				$len = Matchfinder.lz_extend(input, in_next, match_at, $len.plus_wrap(1), max_len)
				if $len > $best_len {
					$best_len = $len
					$cache_len = match List.set($cache_len, $cache_ptr, $len.to_u32_wrap()) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$cache_off = match List.set($cache_off, $cache_ptr, in_next.minus_wrap(match_at).to_u32_wrap()) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$cache_ptr = $cache_ptr.plus_wrap(1)
					if $len >= nice_len {
						# Long enough to stop: hand this node's subtrees to the
						# two pending slots and leave the tree as it stands.
						ns = $node.to_u64().bitwise_and(32767).times_wrap(2)
						node_lt = List.get($child, ns) ?? 0
						node_gt = List.get($child, ns.plus_wrap(1)) ?? 0
						$child = match List.set($child, $pending_lt, node_lt) {
							Ok(next) => next
							Err(_) => return Err(CompressBug)
						}
						$child = match List.set($child, $pending_gt, node_gt) {
							Ok(next) => next
							Err(_) => return Err(CompressBug)
						}
						$walking = 0
					} else {
					}
				} else {
				}
			} else {
			}

			if $walking == 1 {
				ns = $node.to_u64().bitwise_and(32767).times_wrap(2)
				if (List.get(input, match_at.plus_wrap($len)) ?? 0) < (List.get(input, in_next.plus_wrap($len)) ?? 0) {
					# This node sorts before the current position, so it and its
					# left subtree belong to the lesser side.
					$child = match List.set($child, $pending_lt, $node) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$pending_lt = ns.plus_wrap(1)
					$node = List.get($child, $pending_lt) ?? 0
					$best_lt_len = $len
					if $best_gt_len < $len {
						$len = $best_gt_len
					} else {
					}
				} else {
					$child = match List.set($child, $pending_gt, $node) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$pending_gt = ns
					$node = List.get($child, $pending_gt) ?? 0
					$best_gt_len = $len
					if $best_lt_len < $len {
						$len = $best_lt_len
					} else {
					}
				}

				$depth = $depth.minus_wrap(1)
				if $node.to_u64() <= cur_pos or $depth == 0 {
					$child = match List.set($child, $pending_lt, 0) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$child = match List.set($child, $pending_gt, 0) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$walking = 0
				} else {
				}
			} else {
			}
		}

		Ok({
			hash3: $tab3,
			hash4: $tab4,
			child: $child,
			next_hash3: out_hash3,
			next_hash4: out_hash4,
			cache_len: $cache_len,
			cache_off: $cache_off,
			cache_ptr: $cache_ptr,
		})
	}

	## Advance one byte without reporting anything, which is how the positions
	## covered by an already-chosen long match are passed over.
	##
	## The tree still has to be walked and rebuilt, so this is nearly the same
	## work as a search; the walk simply stops at `nice_len` rather than at the
	## caller's maximum length.
	skip_byte : List(U16), List(U16), List(U16), U64, U64, List(U8), U64, U64, U64, U64 -> Try(State, [CompressBug])
	skip_byte = |tab3_0, tab4_0, child_0, nh3, nh4, input, in_base, cur_pos, nice_len, max_search_depth| {
		var $tab3 = tab3_0
		var $tab4 = tab4_0
		var $child = child_0

		in_next = in_base.plus_wrap(cur_pos)
				next_hashseq = U32.from_le_bytes(input, in_next.plus_wrap(1)) ?? 0
		hash3 = nh3
		hash4 = nh4
		out_hash3 = Matchfinder.lz_hash(next_hashseq.bitwise_and(0xFFFFFF), BtMatchfinder.hash3_order)
		out_hash4 = Matchfinder.lz_hash(next_hashseq, BtMatchfinder.hash4_order)
		pos = cur_pos.plus_wrap(Matchfinder.node_bias).to_u16_wrap()

		slot3 = hash3.times_wrap(2)
		node3 = List.get($tab3, slot3) ?? 0
		$tab3 = match List.set($tab3, slot3, pos) {
			Ok(next) => next
			Err(_) => return Err(CompressBug)
		}
		$tab3 = match List.set($tab3, slot3.plus_wrap(1), node3) {
			Ok(next) => next
			Err(_) => return Err(CompressBug)
		}

		node4 = List.get($tab4, hash4) ?? 0
		$tab4 = match List.set($tab4, hash4, pos) {
			Ok(next) => next
			Err(_) => return Err(CompressBug)
		}

		var $pending_lt = cur_pos.bitwise_and(32767).times_wrap(2)
		var $pending_gt = $pending_lt.plus_wrap(1)

		if node4.to_u64() <= cur_pos {
			$child = match List.set($child, $pending_lt, 0) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$child = match List.set($child, $pending_gt, 0) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			return Ok({
				hash3: $tab3,
				hash4: $tab4,
				child: $child,
				next_hash3: out_hash3,
				next_hash4: out_hash4,
			})
		} else {
		}

		var $node = node4
		var $depth = max_search_depth
		var $best_lt_len = 0.U64
		var $best_gt_len = 0.U64
		var $len = 0.U64
		var $walking = 1.U64

		while $walking == 1 {
			match_at = Matchfinder.node_index(in_base, $node)

			if (List.get(input, match_at.plus_wrap($len)) ?? 0) == (List.get(input, in_next.plus_wrap($len)) ?? 0) {
				$len = Matchfinder.lz_extend(input, in_next, match_at, $len.plus_wrap(1), nice_len)
				if $len >= nice_len {
					ns = $node.to_u64().bitwise_and(32767).times_wrap(2)
					node_lt = List.get($child, ns) ?? 0
					node_gt = List.get($child, ns.plus_wrap(1)) ?? 0
					$child = match List.set($child, $pending_lt, node_lt) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$child = match List.set($child, $pending_gt, node_gt) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$walking = 0
				} else {
				}
			} else {
			}

			if $walking == 1 {
				ns = $node.to_u64().bitwise_and(32767).times_wrap(2)
				if (List.get(input, match_at.plus_wrap($len)) ?? 0) < (List.get(input, in_next.plus_wrap($len)) ?? 0) {
					$child = match List.set($child, $pending_lt, $node) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$pending_lt = ns.plus_wrap(1)
					$node = List.get($child, $pending_lt) ?? 0
					$best_lt_len = $len
					if $best_gt_len < $len {
						$len = $best_gt_len
					} else {
					}
				} else {
					$child = match List.set($child, $pending_gt, $node) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$pending_gt = ns
					$node = List.get($child, $pending_gt) ?? 0
					$best_gt_len = $len
					if $best_lt_len < $len {
						$len = $best_lt_len
					} else {
					}
				}

				$depth = $depth.minus_wrap(1)
				if $node.to_u64() <= cur_pos or $depth == 0 {
					$child = match List.set($child, $pending_lt, 0) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$child = match List.set($child, $pending_gt, 0) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$walking = 0
				} else {
				}
			} else {
			}
		}

		Ok({
			hash3: $tab3,
			hash4: $tab4,
			child: $child,
			next_hash3: out_hash3,
			next_hash4: out_hash4,
		})
	}
}
