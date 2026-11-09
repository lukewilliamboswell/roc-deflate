import DeflateTables

## Length-limited canonical Huffman code construction, ported from
## libdeflate's `deflate_make_huffman_code` and the routines it calls.
##
## The shape follows libdeflate rather than a textbook Huffman builder, and
## every departure would cost either speed or output bytes:
##
##   - symbols are sorted by a counting sort over one counter per symbol, with
##     only the top counter's contents handed to a heapsort, because most
##     frequencies are small
##   - the tree keeps only non-leaf nodes, stored in the same array as the
##     frequencies, holding parent indices rather than child pointers, because a
##     canonical code needs only the number of leaves at each depth, which
##     that stripped tree yields
##   - the length limit is met by clamping depths as they are computed rather
##     than by a second pass
##
## Each array entry packs a symbol in the low [HuffmanEncode.num_symbol_bits]
## bits and a frequency (later a parent index, later a depth) above it.
HuffmanEncode := [].{

	## Bits of each packed entry that hold the symbol.
	num_symbol_bits : U64
	num_symbol_bits = 10

	symbol_mask : U32
	symbol_mask = 0x3FF

	freq_mask : U32
	freq_mask = 0xFFFFFC00

	## The longest codeword DEFLATE allows in any of its codes.
	max_codeword_len : U64
	max_codeword_len = 15

	## Restore the maxheap property in the subtree rooted at `subtree_idx`,
	## whose children already satisfy it, by sifting the root down. Indices are
	## 1-based over the window that starts at `base`, matching libdeflate's
	## pointer decrement.
	heapify_subtree : List(U32), U64, U64, U64 -> List(U32)
	heapify_subtree = |a0, base, length, subtree_idx| {
		var $a = a0
		v = List.get($a, base + subtree_idx - 1) ?? 0
		var $parent_idx = subtree_idx
		var $sifting = True
		while $sifting {
			child_idx0 = $parent_idx * 2
			if child_idx0 > length {
				$sifting = False
			} else {
				# Take the greater of the two children.
				child_idx =
					if child_idx0 < length
						and (List.get($a, base + child_idx0) ?? 0)
							> (List.get($a, base + child_idx0 - 1) ?? 0) {
						child_idx0 + 1
					} else {
						child_idx0
					}
				child = List.get($a, base + child_idx - 1) ?? 0
				if v >= child {
					$sifting = False
				} else {
					$a = match List.set($a, base + $parent_idx - 1, child) {
						Ok(next) => next
						Err(_) => crash "HuffmanEncode.heapify_subtree: a index out of bounds"
					}
					$parent_idx = child_idx
				}
			}
		}
		match List.set($a, base + $parent_idx - 1, v) {
			Ok(next) => next
			Err(_) => crash "HuffmanEncode.heapify_subtree: a index out of bounds"
		}
	}

	## Sort `length` entries starting at `base` ascending, by heapsort.
	heap_sort : List(U32), U64, U64 -> List(U32)
	heap_sort = |a0, base, length| {
		var $a = a0

		# Build the heap, bottom up.
		var $subtree_idx = length // 2
		while $subtree_idx >= 1 {
			$a = HuffmanEncode.heapify_subtree($a, base, length, $subtree_idx)
			$subtree_idx = $subtree_idx - 1
		}

		# Repeatedly move the maximum to the end of the shrinking heap.
		var $len = length
		while $len >= 2 {
			last = List.get($a, base + $len - 1) ?? 0
			first = List.get($a, base) ?? 0
			$a = match List.set($a, base + $len - 1, first) {
				Ok(next) => next
				Err(_) => crash "HuffmanEncode.heap_sort: a index out of bounds"
			}
			$a = match List.set($a, base, last) {
				Ok(next) => next
				Err(_) => crash "HuffmanEncode.heap_sort: a index out of bounds"
			}
			$len = $len - 1
			$a = HuffmanEncode.heapify_subtree($a, base, $len, 1)
		}
		$a
	}

	SortedSymbols : { symout : List(U32), lens : List(U8), num_used_syms : U64 }

	## Sort the symbols by frequency, then by symbol value, discarding those
	## with zero frequency and setting their codeword lengths to zero.
	##
	## Most frequencies are small, so a counting sort over one counter per
	## symbol places nearly every symbol directly. Only the symbols that landed
	## in the saturating top counter need the comparison sort.
	sort_symbols : U64, List(U32), List(U8), List(U32) -> SortedSymbols
	sort_symbols = |num_syms, freqs, lens0, symout0| {
		var $lens = lens0
		var $symout = symout0
		num_counters = num_syms
		top = num_counters - 1

		var $counters = List.repeat(0.U64, num_counters)
		var $sym = 0.U64
		while $sym < num_syms {
			slot = (List.get(freqs, $sym) ?? 0).to_u64().min(top)
			slot_count = (List.get($counters, slot) ?? 0) + 1
			$counters = match List.set($counters, slot, slot_count) {
				Ok(next) => next
				Err(_) => crash "HuffmanEncode.sort_symbols: counters index out of bounds"
			}
			$sym = $sym + 1
		}

		# Make the counters cumulative, skipping the zero-th, which counted the
		# unused symbols. This also totals the symbols that are used.
		var $num_used_syms = 0.U64
		var $i = 1.U64
		while $i < num_counters {
			count = List.get($counters, $i) ?? 0
			$counters = match List.set($counters, $i, $num_used_syms) {
				Ok(next) => next
				Err(_) => crash "HuffmanEncode.sort_symbols: counters index out of bounds"
			}
			$num_used_syms = $num_used_syms + count
			$i = $i + 1
		}

		$sym = 0
		while $sym < num_syms {
			freq = List.get(freqs, $sym) ?? 0
			if freq != 0 {
				slot = freq.to_u64().min(top)
				at = List.get($counters, slot) ?? 0
				$counters = match List.set($counters, slot, at + 1) {
					Ok(next) => next
					Err(_) => crash "HuffmanEncode.sort_symbols: counters index out of bounds"
				}
				packed = $sym.to_u32_wrap().bitwise_or(freq.shl_wrap(HuffmanEncode.num_symbol_bits.to_u8_wrap()))
				$symout = match List.set($symout, at, packed) {
					Ok(next) => next
					Err(_) => crash "HuffmanEncode.sort_symbols: symout index out of bounds"
				}
			} else {
				$lens = match List.set($lens, $sym, 0) {
					Ok(next) => next
					Err(_) => crash "HuffmanEncode.sort_symbols: lens index out of bounds"
				}
			}
			$sym = $sym + 1
		}

		# Sort the symbols that saturated the last counter.
		sort_base = List.get($counters, num_counters - 2) ?? 0
		sort_len = (List.get($counters, top) ?? 0) - sort_base
		$symout = HuffmanEncode.heap_sort($symout, sort_base, sort_len)

		{ symout: $symout, lens: $lens, num_used_syms: $num_used_syms }
	}

	## Build the stripped-down Huffman tree in place: only non-leaf nodes, each
	## holding its parent's index.
	##
	## Both the leaves and the parentless non-leaves are already in ascending
	## frequency order, so the next two lowest-frequency nodes are always
	## reachable without a heap: they are the next two leaves, the next two
	## non-leaves, or one of each.
	build_tree : List(U32), U64 -> List(U32)
	build_tree = |a0, sym_count| {
		var $a = a0
		last_idx = sym_count - 1

		# Next leaf, next parentless non-leaf, and next slot for a new node.
		var $i = 0.U64
		var $b = 0.U64
		var $e = 0.U64

		var $building = True
		while $building {
			freq_i = (List.get($a, $i) ?? 0).bitwise_and(HuffmanEncode.freq_mask)
			freq_i1 = (List.get($a, $i + 1) ?? 0).bitwise_and(HuffmanEncode.freq_mask)
			freq_b = (List.get($a, $b) ?? 0).bitwise_and(HuffmanEncode.freq_mask)
			freq_b1 = (List.get($a, $b + 1) ?? 0).bitwise_and(HuffmanEncode.freq_mask)
			parent = $e.to_u32_wrap().shl_wrap(HuffmanEncode.num_symbol_bits.to_u8_wrap())

			new_freq =
				if $i + 1 <= last_idx and ($b == $e or freq_i1 <= freq_b) {
					# Two leaves.
					$i = $i + 2
					freq_i.plus_wrap(freq_i1)
				} else if $b + 2 <= $e and ($i > last_idx or freq_b1 < freq_i) {
					# Two non-leaves, which both gain this node as parent.
					sym_b = (List.get($a, $b) ?? 0).bitwise_and(HuffmanEncode.symbol_mask)
					sym_b1 = (List.get($a, $b + 1) ?? 0).bitwise_and(HuffmanEncode.symbol_mask)
					$a = match List.set($a, $b, parent.bitwise_or(sym_b)) {
						Ok(next) => next
						Err(_) => crash "HuffmanEncode.build_tree: a index out of bounds"
					}
					$a = match List.set($a, $b + 1, parent.bitwise_or(sym_b1)) {
						Ok(next) => next
						Err(_) => crash "HuffmanEncode.build_tree: a index out of bounds"
					}
					$b = $b + 2
					freq_b.plus_wrap(freq_b1)
				} else {
					# One leaf and one non-leaf.
					sym_b = (List.get($a, $b) ?? 0).bitwise_and(HuffmanEncode.symbol_mask)
					$a = match List.set($a, $b, parent.bitwise_or(sym_b)) {
						Ok(next) => next
						Err(_) => crash "HuffmanEncode.build_tree: a index out of bounds"
					}
					$i = $i + 1
					$b = $b + 1
					freq_i.plus_wrap(freq_b)
				}

			sym_e = (List.get($a, $e) ?? 0).bitwise_and(HuffmanEncode.symbol_mask)
			$a = match List.set($a, $e, new_freq.bitwise_or(sym_e)) {
				Ok(next) => next
				Err(_) => crash "HuffmanEncode.build_tree: a index out of bounds"
			}
			$e = $e + 1
			# A tree with n leaves has n - 1 non-leaves.
			if $e >= last_idx {
				$building = False
			} else {
			}
		}
		$a
	}

	## Count how many codewords each length gets, honoring the length limit.
	##
	## Walking the array in reverse visits every parent before its children, so
	## one pass turns parent indices into depths. The count starts as if the
	## root's two children were leaves, and each node visited moves one codeword
	## from its own depth to two at the next depth down. A depth past the limit
	## is clamped to the deepest length already in use, which is what keeps the
	## code length-limited.
	compute_length_counts : List(U32), U64, U64 -> { a : List(U32), len_counts : List(U64) }
	compute_length_counts = |a0, root_idx, max_len| {
		var $a = a0
		var $len_counts = List.repeat(0.U64, max_len + 2)
		$len_counts = match List.set($len_counts, 1, 2) {
			Ok(next) => next
			Err(_) => crash "HuffmanEncode.compute_length_counts: len_counts index out of bounds"
		}

		# The root sits at depth zero.
		root_sym = (List.get($a, root_idx) ?? 0).bitwise_and(HuffmanEncode.symbol_mask)
		$a = match List.set($a, root_idx, root_sym) {
			Ok(next) => next
			Err(_) => crash "HuffmanEncode.compute_length_counts: a index out of bounds"
		}

		var $node_plus_1 = root_idx
		while $node_plus_1 >= 1 {
			node = $node_plus_1 - 1
			entry = List.get($a, node) ?? 0
			parent = entry.shr_zf_wrap(HuffmanEncode.num_symbol_bits.to_u8_wrap()).to_u64()
			parent_depth = (List.get($a, parent) ?? 0).shr_zf_wrap(HuffmanEncode.num_symbol_bits.to_u8_wrap()).to_u64()
			depth0 = parent_depth + 1

			# Record this node's depth so its own children can read it.
			$a = match List.set($a, node, entry.bitwise_and(HuffmanEncode.symbol_mask)
					.bitwise_or(depth0.to_u32_wrap().shl_wrap(HuffmanEncode.num_symbol_bits.to_u8_wrap()))) {
				Ok(next) => next
				Err(_) => crash "HuffmanEncode.compute_length_counts: a index out of bounds"
			}

			var $depth = depth0
			if $depth >= max_len {
				$depth = max_len
				var $scanning = True
				while $scanning {
					$depth = $depth - 1
					if (List.get($len_counts, $depth) ?? 0) != 0 {
						$scanning = False
					} else {
					}
				}
			} else {
			}

			$len_counts = match List.set($len_counts, $depth, (List.get($len_counts, $depth) ?? 0) - 1) {
				Ok(next) => next
				Err(_) => crash "HuffmanEncode.compute_length_counts: len_counts index out of bounds"
			}
			len_counts_count = (List.get($len_counts, $depth + 1) ?? 0) + 2
			$len_counts = match List.set($len_counts, $depth + 1, len_counts_count) {
				Ok(next) => next
				Err(_) => crash "HuffmanEncode.compute_length_counts: len_counts index out of bounds"
			}
			$node_plus_1 = node
		}
		{ a: $a, len_counts: $len_counts }
	}

	## Reverse the low `len` bits of a codeword. DEFLATE writes codewords most
	## significant bit first, while the bit writer emits low bits first.
	reverse_codeword : U32, U64 -> U32
	reverse_codeword = |codeword, len| {
		lo = (List.get(HuffmanEncode.bitreverse_tab, codeword.bitwise_and(0xFF).to_u64()) ?? 0).to_u32()
		hi = (List.get(HuffmanEncode.bitreverse_tab, codeword.shr_zf_wrap(8).to_u64()) ?? 0).to_u32()
		lo.shl_wrap(8).bitwise_or(hi).shr_zf_wrap((16 - len).to_u8_wrap())
	}

	## Byte-reversal table, as libdeflate uses when the target has no bit
	## reversal instruction.
	bitreverse_tab : List(U8)
	bitreverse_tab = {
		var $out = List.with_capacity(256)
		var $i = 0.U64
		while $i < 256 {
			b = $i.to_u8_wrap()
			r0 = b.shr_zf_wrap(4).bitwise_or(b.shl_wrap(4))
			r1 = r0.bitwise_and(0xCC).shr_zf_wrap(2).bitwise_or(r0.bitwise_and(0x33).shl_wrap(2))
			r2 = r1.bitwise_and(0xAA).shr_zf_wrap(1).bitwise_or(r1.bitwise_and(0x55).shl_wrap(1))
			$out = List.append($out, r2)
			$i = $i + 1
		}
		$out
	}

	## Assign a codeword length to every symbol and generate the codewords.
	##
	## Lengths go to the symbols in decreasing order, against the ascending
	## frequency order the array is already in, so the rarest symbols get the
	## longest codewords. The codewords themselves come from a running first
	## codeword per length, which is what makes the code canonical.
	gen_codewords : List(U32), List(U8), List(U64), U64, U64 -> { a : List(U32), lens : List(U8) }
	gen_codewords = |a0, lens0, len_counts, max_len, num_syms| {
		var $a = a0
		var $lens = lens0

		var $i = 0.U64
		var $len = max_len
		while $len >= 1 {
			var $count = List.get(len_counts, $len) ?? 0
			while $count > 0 {
				sym = (List.get($a, $i) ?? 0).bitwise_and(HuffmanEncode.symbol_mask).to_u64()
				$lens = match List.set($lens, sym, $len.to_u8_wrap()) {
					Ok(next) => next
					Err(_) => crash "HuffmanEncode.gen_codewords: lens index out of bounds"
				}
				$i = $i + 1
				$count = $count - 1
			}
			$len = $len - 1
		}

		# The lexicographically first codeword of each length.
		var $next_codewords = List.repeat(0.U32, HuffmanEncode.max_codeword_len + 2)
		var $l = 2.U64
		while $l <= max_len {
			prev = List.get($next_codewords, $l - 1) ?? 0
			prev_count = (List.get(len_counts, $l - 1) ?? 0).to_u32_wrap()
			$next_codewords = match List.set($next_codewords, $l, prev.plus_wrap(prev_count).shl_wrap(1)) {
				Ok(next) => next
				Err(_) => crash "HuffmanEncode.gen_codewords: next_codewords index out of bounds"
			}
			$l = $l + 1
		}

		var $sym = 0.U64
		while $sym < num_syms {
			sym_len = (List.get($lens, $sym) ?? 0).to_u64()
			codeword = List.get($next_codewords, sym_len) ?? 0
			$next_codewords = match List.set($next_codewords, sym_len, codeword + 1) {
				Ok(next) => next
				Err(_) => crash "HuffmanEncode.gen_codewords: next_codewords index out of bounds"
			}
			$a = match List.set($a, $sym, HuffmanEncode.reverse_codeword(codeword, sym_len)) {
				Ok(next) => next
				Err(_) => crash "HuffmanEncode.gen_codewords: a index out of bounds"
			}
			$sym = $sym + 1
		}
		{ a: $a, lens: $lens }
	}

	Code : { lens : List(U8), codewords : List(U32) }

	## Build a length-limited canonical Huffman code for one alphabet.
	##
	## The caller supplies the scratch lists for the lengths and codewords. The
	## codeword list doubles as the sort and tree array while the code is being
	## built, exactly as libdeflate reuses that storage.
	make_code : U64, U64, List(U32), List(U8), List(U32) -> Code
	make_code = |num_syms, max_len, freqs, lens0, codewords0| {
		sorted = HuffmanEncode.sort_symbols(num_syms, freqs, lens0, codewords0)
		num_used_syms = sorted.num_used_syms

		if num_used_syms < 2 {
			# A complete code needs two codewords. Some decompressors reject
			# codes with fewer, so emit codeword '0' for symbol 0 and '1' for
			# the used symbol, or symbol 1 when the used symbol is 0.
			var $lens = sorted.lens
			var $codewords = sorted.symout
			sym =
				if num_used_syms == 1 {
					(List.get($codewords, 0) ?? 0).bitwise_and(HuffmanEncode.symbol_mask).to_u64()
				} else {
					0
				}
			nonzero_idx = if sym != 0 { sym } else { 1 }

			$codewords = match List.set($codewords, 0, 0) {
				Ok(next) => next
				Err(_) => crash "HuffmanEncode.make_code: codewords index out of bounds"
			}
			$lens = match List.set($lens, 0, 1) {
				Ok(next) => next
				Err(_) => crash "HuffmanEncode.make_code: lens index out of bounds"
			}
			$codewords = match List.set($codewords, nonzero_idx, 1) {
				Ok(next) => next
				Err(_) => crash "HuffmanEncode.make_code: codewords index out of bounds"
			}
			$lens = match List.set($lens, nonzero_idx, 1) {
				Ok(next) => next
				Err(_) => crash "HuffmanEncode.make_code: lens index out of bounds"
			}
			{ lens: $lens, codewords: $codewords }
		} else {
			built = HuffmanEncode.build_tree(sorted.symout, num_used_syms)
			counted = HuffmanEncode.compute_length_counts(built, num_used_syms - 2, max_len)
			generated = HuffmanEncode.gen_codewords(
				counted.a,
				sorted.lens,
				counted.len_counts,
				max_len,
				num_syms,
			)
			{ lens: generated.lens, codewords: generated.a }
		}
	}
}
