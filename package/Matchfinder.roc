## Pieces shared by the Lempel-Ziv matchfinders, ported from libdeflate's
## `matchfinder_common.h`.
##
## Positions are stored as 16-bit values relative to a base that slides
## through the input a window at a time, biased by the window size (see
## `node_bias`): a never-written slot is zero and one unsigned comparison
## against the current position rejects it together with every stale entry,
## so the tables start as plain zeros.
Matchfinder := [].{

	window_order : U64
	window_order = 15

	window_size : U64
	window_size = 32768

	## Hash a sequence prefix held in the low bits of a 32-bit value.
	##
	## The multiply spreads the prefix over the whole word and the shift keeps
	## the high bits of the product, which carry the most randomness.
	lz_hash : U32, U64 -> U64
	lz_hash = |seq, num_bits|
		seq.times_wrap(0x1E35A7BD).shr_zf_wrap((32 - num_bits).to_u8_wrap()).to_u64()

	## A node is `position + window_size`, so the initial
	## value is zero, a stale entry is rejected by an unsigned comparison
	## against the current position, the chain slot is the node masked, and
	## the absolute index is a wrapping add. Nothing in the chain walk then
	## needs the node sign-extended, which keeps the next read's address one
	## mask away from the load.
	node_bias : U64
	node_bias = 32768

	init_nodes : U64 -> List(U16)
	init_nodes = |num_entries|
		List.repeat(0.U16, num_entries)

	## Slide a node table back by one window: a saturating subtract, since a
	## node already in the first window stays permanently out of it.
	rebase_nodes : List(U16) -> List(U16)
	rebase_nodes = |table|
		List.map(table, |v| if v >= 32768 { v.minus_wrap(32768) } else { 0 })

	## Absolute input index of a biased node.
	node_index : U64, U16 -> U64
	node_index = |in_base, node|
		in_base.plus_wrap(node.to_u64()).minus_wrap(Matchfinder.node_bias)

	## Number of bytes at `match_at` that equal the bytes at `str_at`, counting
	## the `start_len` bytes the caller already matched and stopping at
	## `max_len`.
	##
	## Whole words are compared at a time and the first differing word is
	## located by its lowest set bit, so a mismatch costs one count rather than
	## a byte loop. The caller guarantees `max_len` bytes are readable at both
	## positions, which is what makes the word reads safe.
	lz_extend : List(U8), U64, U64, U64, U64 -> U64
	lz_extend = |input, str_at, match_at, start_len, max_len| {
		# Wrapping index arithmetic: a checked add would put an overflow branch
		# ahead of every word read, and the reads' own bounds tests already
		# reject any position that wrapped.
		var $len = start_len

		# Four word compares cover most matches. Each returns the match length
		# as soon as its words differ, so the loop carries nothing but its
		# counter and unrolls into straight compares.
		if max_len.minus_wrap($len) >= 32 {
			var $step = 0.U64
			while $step < 4 {
				d = (U64.from_le_bytes(input, match_at.plus_wrap($len)) ?? 0)
					.bitwise_xor(U64.from_le_bytes(input, str_at.plus_wrap($len)) ?? 0)
				if d != 0 {
					return $len.plus_wrap(d.count_trailing_zero_bits().to_u64().shr_zf_wrap(3))
				} else {
				}
				$len = $len.plus_wrap(8)
				$step = $step.plus_wrap(1)
			}
		} else {
		}

		while $len.plus_wrap(8) <= max_len {
			d = (U64.from_le_bytes(input, match_at.plus_wrap($len)) ?? 0)
				.bitwise_xor(U64.from_le_bytes(input, str_at.plus_wrap($len)) ?? 0)
			if d != 0 {
				return $len.plus_wrap(d.count_trailing_zero_bits().to_u64().shr_zf_wrap(3))
			} else {
			}
			$len = $len.plus_wrap(8)
		}

		while $len < max_len
			and (List.get(input, match_at.plus_wrap($len)) ?? 0) == (List.get(input, str_at.plus_wrap($len)) ?? 0) {
			$len = $len.plus_wrap(1)
		}
		$len
	}
}
