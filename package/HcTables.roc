import Matchfinder
import HcMatchfinder

## Hash-chain tables and insertion of positions skipped by a match.
## The greedy and lazy parsers share this layout: length-3 hash heads,
## length-4 hash heads, and window-sized chain links, all stored as U16.
## The search loops live in CompressLazy so their bounds remain visible
## alongside the surrounding parser state. Keep the four copies of
## libdeflate's hc_matchfinder_longest_match consistent: the greedy search
## and the lazy parser's three searches.
HcTables := [].{
	State : {
		head3 : List(U16),
		head4 : List(U16),
		chain : List(U16),
		in_cur_base : U64,
		next_hash3 : U64,
		next_hash4 : U64,
	}

	skip_bytes : List(U16), List(U16), List(U16), U64, U64, U64, List(U8), U64, U64, U64 -> Try(State, [])
	skip_bytes = |head3_0, head4_0, chain_0, base_0, nh3_0, nh4_0, input, in_next0, in_end, count| {
		# Include the lookahead used to hash the following position.
		end = in_next0.plus_wrap(count)
		if end.plus_wrap(5) > in_end or in_end > List.len(input) {
			Ok({ head3: head3_0, head4: head4_0, chain: chain_0, in_cur_base: base_0, next_hash3: nh3_0, next_hash4: nh4_0 })
		} else {
			var $head3 = head3_0
			var $head4 = head4_0
			var $chain = chain_0
			var $base = base_0
			var $cur_pos = in_next0.minus_wrap(base_0).to_i64_wrap()
			# A match is shorter than the window, so at most one slide is needed.
			if $cur_pos.plus_wrap(count.to_i64_wrap()).minus_wrap(1) >= Matchfinder.window_size.to_i64_wrap() {
				$head3 = Matchfinder.rebase_nodes($head3)
				$head4 = Matchfinder.rebase_nodes($head4)
				$chain = Matchfinder.rebase_nodes($chain)
				$base = $base.plus_wrap(Matchfinder.window_size)
				$cur_pos = $cur_pos.minus_wrap(Matchfinder.window_size.to_i64_wrap())
			} else {}
			# Establish table and initial hash bounds once, before the byte loop.
			if List.len($head3) < HcMatchfinder.hash3_size
				or List.len($head4) < HcMatchfinder.hash4_size
				or List.len($chain) < Matchfinder.window_size
				or nh3_0 >= HcMatchfinder.hash3_size
				or nh4_0 >= HcMatchfinder.hash4_size {
				crash "HcTables.skip_bytes: invalid tables or hash"
			} else {}
			var $in_next = in_next0
			var $hash3 = nh3_0
			var $hash4 = nh4_0
			while $in_next < end {
				pos = $cur_pos.plus_wrap(Matchfinder.node_bias.to_i64_wrap()).to_u16_wrap()
				slot = $cur_pos.to_u64_wrap().bitwise_and(32767)
				prev_head = List.get($head4, $hash4) ?? 0
				$head3 = List.set($head3, $hash3, pos) ?? crash "hash3 outside table"
				$chain = List.set($chain, slot, prev_head) ?? crash "chain outside table"
				$head4 = List.set($head4, $hash4, pos) ?? crash "hash4 outside table"
				$in_next = $in_next.plus_wrap(1)
				next_hashseq = U32.from_le_bytes(input, $in_next) ?? 0
				$hash3 = Matchfinder.lz_hash(next_hashseq.bitwise_and(0xFFFFFF), HcMatchfinder.hash3_order)
				$hash4 = Matchfinder.lz_hash(next_hashseq, HcMatchfinder.hash4_order)
				$cur_pos = $cur_pos.plus_wrap(1)
			}
			Ok({ head3: $head3, head4: $head4, chain: $chain, in_cur_base: $base, next_hash3: $hash3, next_hash4: $hash4 })
		}
	}
}
