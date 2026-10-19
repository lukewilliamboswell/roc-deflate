import DeflateTables
import HuffmanEncode

## Choosing a block's type and writing it out, ported from libdeflate's
## `deflate_flush_block` and the header precomputation it calls.
##
## The bit writer keeps its state in loop-local values rather than a record
## that helper calls thread back and forth, and the bit operations are written
## out at each site instead of being factored into functions. That is what
## libdeflate's ADD_BITS/FLUSH_BITS macros buy: on a 64-bit bit buffer, four
## literals or one whole match fit between flushes, so a literal run costs one
## store per four symbols rather than a call per symbol.
BlockOut := [].{

	## Codeword tables for one block's two Huffman codes.
	Codes : {
		litlen_lens : List(U8),
		litlen_codewords : List(U32),
		offset_lens : List(U8),
		offset_codewords : List(U32),
	}

	## One run of literals followed by a match, or by the end of the block.
	##
	## `litrunlen_and_length` packs the literal count in its low 23 bits and
	## the following match's length above them; a length of zero marks the last
	## sequence in a block. The literals themselves are not stored, since they
	## are read back from the uncompressed input.
	Sequence : {
		litrunlen_and_length : U32,
		offset : U16,
		offset_slot : U16,
	}

	seq_length_shift : U8
	seq_length_shift = 23

	seq_litrunlen_mask : U32
	seq_litrunlen_mask = 0x7FFFFF

	## The bit buffer holds one bit less than a machine word so that shifting
	## by `bitcount & ~7` is always defined.
	bitbuf_nbits : U64
	bitbuf_nbits = 63

	max_litlen_codeword_len : U64
	max_litlen_codeword_len = 14

	max_offset_codeword_len : U64
	max_offset_codeword_len = 15

	max_pre_codeword_len : U64
	max_pre_codeword_len = 7

	## The static Huffman code RFC 1951 defines.
	##
	## It is built as libdeflate builds it, from frequencies that lead
	## `make_code` to exactly the standard lengths, but once, as a constant,
	## rather than once per stream. It is evaluated when the package compiles,
	## so the fallback is never taken.
	static_codes : Codes
	static_codes = BlockOut.build_static_codes({}) ?? BlockOut.init_codes({})

	build_static_codes : {} -> Try(Codes, [CompressBug])
	build_static_codes = |{}| {
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
			HuffmanEncode.init_scratch({}),
		)?
		offset = HuffmanEncode.make_code(
			DeflateTables.num_offset_syms,
			BlockOut.max_offset_codeword_len,
			List.repeat(1.U32, DeflateTables.num_offset_syms),
			List.repeat(0.U8, DeflateTables.num_offset_syms),
			List.repeat(0.U32, DeflateTables.num_offset_syms),
			litlen.scratch,
		)?
		Ok({
			litlen_lens: litlen.lens,
			litlen_codewords: litlen.codewords,
			offset_lens: offset.lens,
			offset_codewords: offset.codewords,
		})
	}

	## Storage the writer reuses from block to block, which libdeflate keeps in
	## its compressor struct. A parser makes one with [BlockOut.init_scratch]
	## per stream and threads it through every block, so writing a block
	## allocates nothing.
	##
	## Besides the precode, everything lives in one list of words, each table
	## in a region of its own: the code builder's scratch (see
	## [HuffmanEncode.init_scratch]) at the start, then the precode items,
	## then the packed tables the symbol writer reads.
	Scratch : {
		words : List(U64),
		precode_freqs : List(U32),
		precode_lens : List(U8),
		precode_codewords : List(U32),
	}

	## Where each table starts in the scratch words.
	precode_items_at : U64
	precode_items_at = DeflateTables.num_litlen_syms

	## A precode item per codeword length at most.
	packed_litlen_at : U64
	packed_litlen_at = BlockOut.precode_items_at + DeflateTables.num_litlen_syms + DeflateTables.num_offset_syms

	## One entry per match length, indexed by the length itself.
	packed_lengths_at : U64
	packed_lengths_at = BlockOut.packed_litlen_at + DeflateTables.num_litlen_syms

	packed_offsets_at : U64
	packed_offsets_at = BlockOut.packed_lengths_at + DeflateTables.max_match_len + 1

	scratch_words_len : U64
	scratch_words_len = BlockOut.packed_offsets_at + DeflateTables.num_offset_syms

	init_scratch : {} -> Scratch
	init_scratch = |{}| {
		words: List.repeat(0.U64, BlockOut.scratch_words_len),
		precode_freqs: List.repeat(0.U32, DeflateTables.num_precode_syms),
		precode_lens: List.repeat(0.U8, DeflateTables.num_precode_syms),
		precode_codewords: List.repeat(0.U32, DeflateTables.num_precode_syms),
	}

	## Storage for one block's codes, to be filled by [BlockOut.make_codes].
	init_codes : {} -> Codes
	init_codes = |{}| {
		litlen_lens: List.repeat(0.U8, DeflateTables.num_litlen_syms),
		litlen_codewords: List.repeat(0.U32, DeflateTables.num_litlen_syms),
		offset_lens: List.repeat(0.U8, DeflateTables.num_offset_syms),
		offset_codewords: List.repeat(0.U32, DeflateTables.num_offset_syms),
	}

	BuiltCodes : { codes : Codes, scratch : Scratch }

	## Build a block's litlen and offset codes from its symbol counts, as
	## libdeflate's `deflate_make_huffman_codes` does, overwriting the codes of
	## an earlier block.
	make_codes : List(U32), List(U32), Codes, Scratch -> Try(BuiltCodes, [CompressBug])
	make_codes = |freqs_litlen, freqs_offset, codes, scratch| {
		{ litlen_lens, litlen_codewords, offset_lens, offset_codewords } = codes
		{ words, precode_freqs, precode_lens, precode_codewords } = scratch
		litlen = HuffmanEncode.make_code(
			DeflateTables.num_litlen_syms,
			BlockOut.max_litlen_codeword_len,
			freqs_litlen,
			litlen_lens,
			litlen_codewords,
			words,
		)?
		offset = HuffmanEncode.make_code(
			DeflateTables.num_offset_syms,
			BlockOut.max_offset_codeword_len,
			freqs_offset,
			offset_lens,
			offset_codewords,
			litlen.scratch,
		)?
		Ok({
			codes: {
				litlen_lens: litlen.lens,
				litlen_codewords: litlen.codewords,
				offset_lens: offset.lens,
				offset_codewords: offset.codewords,
			},
			scratch: {
				words: offset.scratch,
				precode_freqs,
				precode_lens,
				precode_codewords,
			},
		})
	}

	## Zero every count in a list, keeping its storage for the next block.
	clear_counts : List(U32) -> Try(List(U32), [CompressBug])
	clear_counts = |counts| {
		var $counts = counts
		var $i = 0.U64
		while $i < List.len($counts) {
			$counts = match List.set($counts, $i, 0) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$i = $i + 1
		}
		Ok($counts)
	}

	## The header's shape. The precode itself, its symbol frequencies and the
	## items that encode the lengths are left in `scratch`.
	PrecodeInfo : {
		scratch : Scratch,
		num_items : U64,
		num_litlen_syms : U64,
		num_offset_syms : U64,
		num_explicit_lens : U64,
	}

	## The litlen and offset codeword lengths as the one contiguous run the
	## precode encodes: the first `num_litlen_syms` litlen lengths, then the
	## offset lengths.
	combined_len : List(U8), List(U8), U64, U64 -> U8
	combined_len = |litlen_lens, offset_lens, num_litlen_syms, i|
		if i < num_litlen_syms {
			List.get(litlen_lens, i) ?? 0
		} else {
			List.get(offset_lens, i - num_litlen_syms) ?? 0
		}

	## Run-length encode the litlen and offset codeword lengths into precode
	## items, counting how often each precode symbol is used.
	##
	## Each item carries its precode symbol in the low five bits and any extra
	## bits above them. The items go into the scratch words from
	## [BlockOut.precode_items_at].
	compute_precode_items : List(U8), List(U8), U64, U64, List(U32), List(U64) -> Try({ freqs : List(U32), words : List(U64), num_items : U64 }, [CompressBug])
	compute_precode_items = |litlen_lens, offset_lens, num_litlen_syms, num_lens, freqs0, words0| {
		var $freqs = freqs0
		var $words = words0
		var $num_items = 0.U64
		var $run_start = 0.U64

		# The counts are reused from the previous block.
		var $sym = 0.U64
		while $sym < DeflateTables.num_precode_syms {
			$freqs = match List.set($freqs, $sym, 0) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$sym = $sym + 1
		}

		while $run_start != num_lens {
			# Extend the run of equal lengths that starts here.
			len = BlockOut.combined_len(litlen_lens, offset_lens, num_litlen_syms, $run_start)
			var $run_end = $run_start + 1
			while $run_end != num_lens and len == BlockOut.combined_len(litlen_lens, offset_lens, num_litlen_syms, $run_end) {
				$run_end = $run_end + 1
			}

			if len == 0 {
				# Symbol 18 repeats 11 to 138 zeroes, symbol 17 repeats 3 to 10.
				while ($run_end - $run_start) >= 11 {
					extra = (($run_end - $run_start) - 11).min(0x7F)
					freqs_count = (List.get($freqs, 18) ?? 0) + 1
					$freqs = match List.set($freqs, 18, freqs_count) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$words = match List.set($words, BlockOut.precode_items_at + $num_items, (18.U32).bitwise_or(extra.to_u32_wrap().shl_wrap(5)).to_u64()) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$num_items = $num_items + 1
					$run_start = $run_start + 11 + extra
				}
				if ($run_end - $run_start) >= 3 {
					extra = (($run_end - $run_start) - 3).min(0x7)
					freqs_count = (List.get($freqs, 17) ?? 0) + 1
					$freqs = match List.set($freqs, 17, freqs_count) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$words = match List.set($words, BlockOut.precode_items_at + $num_items, (17.U32).bitwise_or(extra.to_u32_wrap().shl_wrap(5)).to_u64()) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$num_items = $num_items + 1
					$run_start = $run_start + 3 + extra
				} else {}
			} else {
				# Symbol 16 repeats the previous length 3 to 6 more times, so
				# the length itself must be written once first.
				if ($run_end - $run_start) >= 4 {
					$freqs = match List.set($freqs, len.to_u64(), (List.get($freqs, len.to_u64()) ?? 0) + 1) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$words = match List.set($words, BlockOut.precode_items_at + $num_items, len.to_u64()) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$num_items = $num_items + 1
					$run_start = $run_start + 1
					var $repeating = True
					while $repeating {
						extra = (($run_end - $run_start) - 3).min(0x3)
						freqs_count = (List.get($freqs, 16) ?? 0) + 1
						$freqs = match List.set($freqs, 16, freqs_count) {
							Ok(next) => next
							Err(_) => return Err(CompressBug)
						}
						$words = match List.set($words, BlockOut.precode_items_at + $num_items, (16.U32).bitwise_or(extra.to_u32_wrap().shl_wrap(5)).to_u64()) {
							Ok(next) => next
							Err(_) => return Err(CompressBug)
						}
						$num_items = $num_items + 1
						$run_start = $run_start + 3 + extra
						if ($run_end - $run_start) < 3 {
							$repeating = False
						} else {}
					}
				} else {}
			}

			# Whatever the run-length symbols could not cover goes out plainly.
			while $run_start != $run_end {
				$freqs = match List.set($freqs, len.to_u64(), (List.get($freqs, len.to_u64()) ?? 0) + 1) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				$words = match List.set($words, BlockOut.precode_items_at + $num_items, len.to_u64()) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				$num_items = $num_items + 1
				$run_start = $run_start + 1
			}
		}
		Ok({ freqs: $freqs, words: $words, num_items: $num_items })
	}

	## Work out everything the dynamic Huffman header needs: how many litlen
	## and offset lengths must be sent, the precode items that encode them, and
	## the precode itself.
	precompute_huffman_header : List(U8), List(U8), Scratch -> Try(PrecodeInfo, [CompressBug])
	precompute_huffman_header = |litlen_lens, offset_lens, scratch| {
		{ words, precode_freqs, precode_lens, precode_codewords } = scratch

		# Trailing unused symbols need not be sent.
		var $num_litlen_syms = DeflateTables.num_litlen_syms
		var $scanning = True
		while $scanning and $num_litlen_syms > 257 {
			if (List.get(litlen_lens, $num_litlen_syms - 1) ?? 0) != 0 {
				$scanning = False
			} else {
				$num_litlen_syms = $num_litlen_syms - 1
			}
		}
		var $num_offset_syms = DeflateTables.num_offset_syms
		$scanning = True
		while $scanning and $num_offset_syms > 1 {
			if (List.get(offset_lens, $num_offset_syms - 1) ?? 0) != 0 {
				$scanning = False
			} else {
				$num_offset_syms = $num_offset_syms - 1
			}
		}

		# The precode encodes both codes' lengths as one contiguous run.
		computed = BlockOut.compute_precode_items(
			litlen_lens,
			offset_lens,
			$num_litlen_syms,
			$num_litlen_syms + $num_offset_syms,
			precode_freqs,
			words,
		)?

		precode = HuffmanEncode.make_code(
			DeflateTables.num_precode_syms,
			BlockOut.max_pre_codeword_len,
			computed.freqs,
			precode_lens,
			precode_codewords,
			computed.words,
		)?

		# Trailing zero precode lengths need not be sent either.
		var $num_explicit_lens = DeflateTables.num_precode_syms
		$scanning = True
		while $scanning and $num_explicit_lens > 4 {
			perm = (List.get(DeflateTables.precode_lens_permutation, $num_explicit_lens - 1) ?? 0).to_u64()
			if (List.get(precode.lens, perm) ?? 0) != 0 {
				$scanning = False
			} else {
				$num_explicit_lens = $num_explicit_lens - 1
			}
		}

		Ok({
			scratch: {
				words: precode.scratch,
				precode_freqs: computed.freqs,
				precode_lens: precode.lens,
				precode_codewords: precode.codewords,
			},
			num_items: computed.num_items,
			num_litlen_syms: $num_litlen_syms,
			num_offset_syms: $num_offset_syms,
			num_explicit_lens: $num_explicit_lens,
		})
	}

	## Concatenate each match length's litlen codeword with its extra bits, so
	## writing a match is one table lookup rather than a slot lookup plus two
	## assembles. Each entry is packed as [BlockOut.pack_codes] packs one, the
	## codeword in the low half and its length above it, into the scratch
	## words from [BlockOut.packed_lengths_at].
	pack_lengths : List(U64), List(U8), List(U32) -> Try(List(U64), [CompressBug])
	pack_lengths = |words, litlen_lens, litlen_codewords| {
		var $packed = words
		var $len = DeflateTables.min_match_len
		while $len <= DeflateTables.max_match_len {
			slot = DeflateTables.length_slot($len)
			litlen_sym = DeflateTables.first_len_sym + slot
			extra_bits = $len.to_u32_wrap() - (List.get(DeflateTables.length_slot_base, slot) ?? 0)
			sym_len = (List.get(litlen_lens, litlen_sym) ?? 0)
			codeword = (List.get(litlen_codewords, litlen_sym) ?? 0)
				.bitwise_or(extra_bits.shl_wrap(sym_len))
			full_len = sym_len + (List.get(DeflateTables.extra_length_bits, slot) ?? 0)
			$packed = match List.set($packed, BlockOut.packed_lengths_at + $len, codeword.to_u64().bitwise_or(full_len.to_u64().shl_wrap(32))) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$len = $len + 1
		}
		Ok($packed)
	}
	OutState : { out : List(U8), bitbuf : U64, bitcount : U64 }

	## Everything the writer hands back: the output and the bit state, plus
	## the lists it borrowed, since a list returns to its owner rather than
	## being left behind at the call.
	FlushResult : {
		out : List(U8),
		bitbuf : U64,
		bitcount : U64,
		seqs : List(Sequence),
		items : List(U32),
		scratch : Scratch,
	}

	## Choose the cheapest of the three block types and write the block.
	##
	## The cost of each type is computed in bits before anything is written,
	## which is what lets the writer commit to a type and then emit the whole
	## block without re-checking anything. Ties prefer uncompressed, then
	## static, then dynamic, as libdeflate does.
	##
	## The chosen literals and matches arrive one of two ways. The greedy and
	## lazy parsers hand over `seqs`, runs of literals each followed by a match,
	## with the literals themselves read back out of the input. The near-optimal
	## parser hands over `items`, one packed entry per position along its chosen
	## path; `use_items` selects between them.
	## A codeword and its length in one word: the codeword in the low half
	## and the length above it. The writer then looks each symbol up once and
	## keeps one table live instead of two. The litlen table goes into the
	## scratch words from [BlockOut.packed_litlen_at].
	pack_codes : List(U64), List(U32), List(U8) -> Try(List(U64), [CompressBug])
	pack_codes = |words, codewords, lens| {
		n = List.len(codewords)
		var $packed = words
		var $i = 0.U64
		while $i < n {
			word = (List.get(codewords, $i) ?? 0).to_u64().bitwise_or((List.get(lens, $i) ?? 0).to_u64().shl_wrap(32))
			$packed = match List.set($packed, BlockOut.packed_litlen_at + $i, word) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$i = $i + 1
		}
		Ok($packed)
	}

	## Everything a match's offset needs in one word: the codeword in the low
	## 16 bits, its length above that, the extra bit count above that, and the
	## slot's base offset in the high half. The table goes into the scratch
	## words from [BlockOut.packed_offsets_at].
	pack_offsets : List(U64), List(U32), List(U8) -> Try(List(U64), [CompressBug])
	pack_offsets = |words, codewords, lens| {
		n = List.len(codewords)
		var $packed = words
		var $i = 0.U64
		while $i < n {
			word = (List.get(codewords, $i) ?? 0).to_u64()
				.bitwise_or((List.get(lens, $i) ?? 0).to_u64().shl_wrap(16))
				.bitwise_or((List.get(DeflateTables.extra_offset_bits, $i) ?? 0).to_u64().shl_wrap(24))
				.bitwise_or((List.get(DeflateTables.offset_slot_base, $i) ?? 0).to_u64().shl_wrap(32))
			$packed = match List.set($packed, BlockOut.packed_offsets_at + $i, word) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$i = $i + 1
		}
		Ok($packed)
	}

	flush_block : List(U8), U64, U64, List(U8), U64, U64, List(BlockOut.Sequence), List(U32), List(U32), Codes, List(U32), U64, U64, Scratch -> Try(FlushResult, [CompressBug])
	flush_block = |out_0, bitbuf_0, bitcount_0, input, block_begin, block_length_0, seqs, freqs_litlen, freqs_offset, codes, items, use_items, is_final, scratch_0| {
		litlen_lens = codes.litlen_lens
		litlen_codewords = codes.litlen_codewords
		offset_lens = codes.offset_lens
		offset_codewords = codes.offset_codewords
		header = BlockOut.precompute_huffman_header(litlen_lens, offset_lens, scratch_0)?
		precode = header.scratch
		s_litlen_lens = BlockOut.static_codes.litlen_lens
		s_litlen_codewords = BlockOut.static_codes.litlen_codewords
		s_offset_lens = BlockOut.static_codes.offset_lens
		s_offset_codewords = BlockOut.static_codes.offset_codewords

		# Cost of the dynamic Huffman header: the three length counts, the
		# explicit precode lengths, then the precode-encoded lengths.
		var $dynamic_cost = 3.U64 + 5 + 5 + 4 + 3 * header.num_explicit_lens
		var $sym = 0.U64
		while $sym < DeflateTables.num_precode_syms {
			extra = (List.get(DeflateTables.extra_precode_bits, $sym) ?? 0).to_u64()
			$dynamic_cost = $dynamic_cost
				+ (List.get(precode.precode_freqs, $sym) ?? 0).to_u64()
					* (extra + (List.get(precode.precode_lens, $sym) ?? 0).to_u64())
			$sym = $sym + 1
		}

		# Literals: the static code spends 8 bits below 144 and 9 above.
		var $static_cost = 3.U64
		$sym = 0
		while $sym < 144 {
			freq = (List.get(freqs_litlen, $sym) ?? 0).to_u64()
			$dynamic_cost = $dynamic_cost + freq * (List.get(litlen_lens, $sym) ?? 0).to_u64()
			$static_cost = $static_cost + freq * 8
			$sym = $sym + 1
		}
		while $sym < 256 {
			freq = (List.get(freqs_litlen, $sym) ?? 0).to_u64()
			$dynamic_cost = $dynamic_cost + freq * (List.get(litlen_lens, $sym) ?? 0).to_u64()
			$static_cost = $static_cost + freq * 9
			$sym = $sym + 1
		}

		# End-of-block.
		$dynamic_cost = $dynamic_cost + (List.get(litlen_lens, DeflateTables.end_of_block) ?? 0).to_u64()
		$static_cost = $static_cost + 7

		# Lengths.
		$sym = 0
		while $sym < 29 {
			extra = (List.get(DeflateTables.extra_length_bits, $sym) ?? 0).to_u64()
			litlen_sym = DeflateTables.first_len_sym + $sym
			freq = (List.get(freqs_litlen, litlen_sym) ?? 0).to_u64()
			$dynamic_cost = $dynamic_cost + freq * (extra + (List.get(litlen_lens, litlen_sym) ?? 0).to_u64())
			$static_cost = $static_cost + freq * (extra + (List.get(s_litlen_lens, litlen_sym) ?? 0).to_u64())
			$sym = $sym + 1
		}

		# Offsets; the static offset code is five bits flat.
		$sym = 0
		while $sym < 30 {
			extra = (List.get(DeflateTables.extra_offset_bits, $sym) ?? 0).to_u64()
			freq = (List.get(freqs_offset, $sym) ?? 0).to_u64()
			$dynamic_cost = $dynamic_cost + freq * (extra + (List.get(offset_lens, $sym) ?? 0).to_u64())
			$static_cost = $static_cost + freq * (extra + 5)
			$sym = $sym + 1
		}

		# An uncompressed block pads to a byte, then spends four bytes of
		# header per 65535 bytes of payload.
		block_length = block_length_0
		num_uncompressed_blocks = (block_length + 65534) // 65535
		uncompressed_cost = 3
			+ (0.U64).minus_wrap(bitcount_0 + 3).bitwise_and(7)
			+ 32
			+ 40 * (num_uncompressed_blocks - 1)
			+ 8 * block_length

		best_cost = $dynamic_cost.min($static_cost).min(uncompressed_cost)

		var $out = out_0
		var $bitbuf = bitbuf_0
		var $bitcount = bitcount_0
		var $in_next = block_begin
		in_end = block_begin + block_length

		if best_cost == uncompressed_cost {
			# Uncompressed. DEFLATE caps a stored block at 65535 bytes, so a
			# longer flush becomes several blocks.
			var $storing = True
			while $storing {
				remaining = in_end - $in_next
				len = remaining.min(65535)
				bfinal = if remaining <= 65535 {
					is_final
				} else {
					0
				}

				# The header is three bits, then the stream aligns to a byte.
				$out = List.append($out, bfinal.shl_wrap($bitcount.to_u8_wrap()).bitwise_or($bitbuf).to_u8_wrap())
				if $bitcount > 5 {
					$out = List.append($out, 0)
				} else {}
				$bitbuf = 0
				$bitcount = 0

				$out = match len.append_le_bytes_to($out, 2) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				$out = match len.bitwise_not().append_le_bytes_to($out, 2) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				$out = List.append_sublist($out, input, { start: $in_next, len })
				$in_next = $in_next + len
				if $in_next == in_end {
					$storing = False
				} else {}
			}
			Ok({
				out: $out,
				bitbuf: $bitbuf,
				bitcount: $bitcount,
				seqs,
				items,
				scratch: header.scratch,
			})
		} else {
			use_static = best_cost == $static_cost

			if use_static {
				$bitbuf = $bitbuf.bitwise_or(is_final.shl_wrap($bitcount.to_u8_wrap()))
				$bitcount = $bitcount + 1
				$bitbuf = $bitbuf.bitwise_or(DeflateTables.blocktype_static.shl_wrap($bitcount.to_u8_wrap()))
				$bitcount = $bitcount + 2
				n = $bitcount.shr_zf_wrap(3)
				$out = match $bitbuf.append_le_bytes_to($out, n.to_u8_wrap()) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				$bitbuf = $bitbuf.shr_zf_wrap(n.shl_wrap(3).to_u8_wrap())
				$bitcount = $bitcount.bitwise_and(7)
			} else {
				$bitbuf = $bitbuf.bitwise_or(is_final.shl_wrap($bitcount.to_u8_wrap()))
				$bitcount = $bitcount + 1
				$bitbuf = $bitbuf.bitwise_or(DeflateTables.blocktype_dynamic.shl_wrap($bitcount.to_u8_wrap()))
				$bitcount = $bitcount + 2
				$bitbuf = $bitbuf.bitwise_or((header.num_litlen_syms - 257).shl_wrap($bitcount.to_u8_wrap()))
				$bitcount = $bitcount + 5
				$bitbuf = $bitbuf.bitwise_or((header.num_offset_syms - 1).shl_wrap($bitcount.to_u8_wrap()))
				$bitcount = $bitcount + 5
				$bitbuf = $bitbuf.bitwise_or((header.num_explicit_lens - 4).shl_wrap($bitcount.to_u8_wrap()))
				$bitcount = $bitcount + 4

				# A 64-bit buffer is one bit too small to hold all 19 precode
				# lengths at once, so the first one goes out with the fields
				# above and the rest follow in a single run.
				perm0 = (List.get(DeflateTables.precode_lens_permutation, 0) ?? 0).to_u64()
				$bitbuf = $bitbuf.bitwise_or((List.get(precode.precode_lens, perm0) ?? 0).to_u64().shl_wrap($bitcount.to_u8_wrap()))
				$bitcount = $bitcount + 3
				n0 = $bitcount.shr_zf_wrap(3)
				$out = match $bitbuf.append_le_bytes_to($out, n0.to_u8_wrap()) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				$bitbuf = $bitbuf.shr_zf_wrap(n0.shl_wrap(3).to_u8_wrap())
				$bitcount = $bitcount.bitwise_and(7)

				var $i = 1.U64
				while $i < header.num_explicit_lens {
					perm = (List.get(DeflateTables.precode_lens_permutation, $i) ?? 0).to_u64()
					$bitbuf = $bitbuf.bitwise_or((List.get(precode.precode_lens, perm) ?? 0).to_u64().shl_wrap($bitcount.to_u8_wrap()))
					$bitcount = $bitcount + 3
					$i = $i + 1
				}
				n1 = $bitcount.shr_zf_wrap(3)
				$out = match $bitbuf.append_le_bytes_to($out, n1.to_u8_wrap()) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				$bitbuf = $bitbuf.shr_zf_wrap(n1.shl_wrap(3).to_u8_wrap())
				$bitcount = $bitcount.bitwise_and(7)

				# Then the litlen and offset lengths, precode-encoded.
				$i = 0
				while $i < header.num_items {
					item = (List.get(precode.words, BlockOut.precode_items_at + $i) ?? 0).to_u32_wrap()
					precode_sym = item.bitwise_and(0x1F).to_u64()
					$bitbuf = $bitbuf.bitwise_or((List.get(precode.precode_codewords, precode_sym) ?? 0).to_u64().shl_wrap($bitcount.to_u8_wrap()))
					$bitcount = $bitcount + (List.get(precode.precode_lens, precode_sym) ?? 0).to_u64()
					$bitbuf = $bitbuf.bitwise_or(item.shr_zf_wrap(5).to_u64().shl_wrap($bitcount.to_u8_wrap()))
					$bitcount = $bitcount + (List.get(DeflateTables.extra_precode_bits, precode_sym) ?? 0).to_u64()
					n = $bitcount.shr_zf_wrap(3)
					$out = match $bitbuf.append_le_bytes_to($out, n.to_u8_wrap()) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$bitbuf = $bitbuf.shr_zf_wrap(n.shl_wrap(3).to_u8_wrap())
					$bitcount = $bitcount.bitwise_and(7)
					$i = $i + 1
				}
			}

			w_litlen_lens = if use_static {
				s_litlen_lens
			} else {
				litlen_lens
			}
			w_litlen_codewords = if use_static {
				s_litlen_codewords
			} else {
				litlen_codewords
			}
			w_offset_lens = if use_static {
				s_offset_lens
			} else {
				offset_lens
			}
			w_offset_codewords = if use_static {
				s_offset_codewords
			} else {
				offset_codewords
			}
			# The tables the symbol writer reads go into the scratch words,
			# which are taken out of the scratch so that they are filled in
			# place.
			{ words: words_0, precode_freqs, precode_lens, precode_codewords } = header.scratch
			words_1 = BlockOut.pack_lengths(words_0, w_litlen_lens, w_litlen_codewords)?
			words_2 = BlockOut.pack_codes(words_1, w_litlen_codewords, w_litlen_lens)?
			words = BlockOut.pack_offsets(words_2, w_offset_codewords, w_offset_lens)?
			# A literal or a match length indexes its packed table directly, so
			# establishing the words' length once here lets the bounds test on
			# every lookup fold away instead of running per symbol.
			if List.len(words) < BlockOut.scratch_words_len {
				return Err(CompressBug)
			} else {}

			# The path holds node `n` at `items_top - n`, appended from the end
			# of the block back to its start.
			items_top = List.len(items).minus_wrap(1)
			var $item_at = if use_items == 1 {
				0.U64
			} else {
				block_length
			}
			while $item_at != block_length {
				item = List.get(items, items_top.minus_wrap($item_at)) ?? 0
				length = item.bitwise_and(0x1FF).to_u64()
				payload = item.shr_zf_wrap(9).to_u64()
				if length == 1 {
					# A length of one marks a literal, whose byte the item
					# carries where a match would carry its offset.
					$bitbuf = $bitbuf.bitwise_or((List.get(w_litlen_codewords, payload) ?? 0).to_u64().shl_wrap($bitcount.to_u8_wrap()))
					$bitcount = $bitcount.plus_wrap((List.get(w_litlen_lens, payload) ?? 0).to_u64())
					n = $bitcount.shr_zf_wrap(3)
					$out = match $bitbuf.append_le_bytes_to($out, n.to_u8_wrap()) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$bitbuf = $bitbuf.shr_zf_wrap(n.shl_wrap(3).to_u8_wrap())
					$bitcount = $bitcount.bitwise_and(7)
				} else {
					offset_slot = DeflateTables.offset_slot(payload)
					packed_len = List.get(words, BlockOut.packed_lengths_at.plus_wrap(length)) ?? 0
					$bitbuf = $bitbuf.bitwise_or(packed_len.bitwise_and(0xFFFF_FFFF).shl_wrap($bitcount.to_u8_wrap()))
					$bitcount = $bitcount.plus_wrap(packed_len.shr_zf_wrap(32))
					$bitbuf = $bitbuf.bitwise_or((List.get(w_offset_codewords, offset_slot) ?? 0).to_u64().shl_wrap($bitcount.to_u8_wrap()))
					$bitcount = $bitcount.plus_wrap((List.get(w_offset_lens, offset_slot) ?? 0).to_u64())
					$bitbuf = $bitbuf.bitwise_or(payload.minus_wrap((List.get(DeflateTables.offset_slot_base, offset_slot) ?? 0).to_u64()).shl_wrap($bitcount.to_u8_wrap()))
					$bitcount = $bitcount.plus_wrap((List.get(DeflateTables.extra_offset_bits, offset_slot) ?? 0).to_u64())
					n = $bitcount.shr_zf_wrap(3)
					$out = match $bitbuf.append_le_bytes_to($out, n.to_u8_wrap()) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$bitbuf = $bitbuf.shr_zf_wrap(n.shl_wrap(3).to_u8_wrap())
					$bitcount = $bitcount.bitwise_and(7)
				}
				$item_at = $item_at.plus_wrap(length)
			}

			# Wrapping arithmetic on the per-symbol path: the bit count never
			# exceeds the buffer's width between flushes, the cursor never
			# passes the block's end, and the sequence index never passes the
			# store's length, so a checked add here would only put an
			# overflow branch on every symbol.
			var $seq_idx = 0.U64
			var $writing = use_items == 0
			while $writing {
				seq = List.get(seqs, $seq_idx) ?? { litrunlen_and_length: 0, offset: 0, offset_slot: 0 }
				var $litrunlen = seq.litrunlen_and_length.bitwise_and(BlockOut.seq_litrunlen_mask).to_u64()
				length = seq.litrunlen_and_length.shr_zf_wrap(BlockOut.seq_length_shift).to_u64()

				# Four literals fit between flushes: 7 leftover bits plus four
				# 14-bit codewords stay inside the 63-bit buffer.
				while $litrunlen >= 4 {
					# The four literals are one word read: the run has at
					# least four bytes left before the block's end, so the
					# read is in bounds, and one bounds test replaces four.
					word = U32.from_le_bytes(input, $in_next) ?? 0
					lit0 = word.bitwise_and(0xFF).to_u64()
					packed0 = List.get(words, BlockOut.packed_litlen_at.plus_wrap(lit0)) ?? 0
					$bitbuf = $bitbuf.bitwise_or(packed0.bitwise_and(0xFFFF_FFFF).shl_wrap($bitcount.to_u8_wrap()))
					$bitcount = $bitcount.plus_wrap(packed0.shr_zf_wrap(32))
					lit1 = word.shr_zf_wrap(8).bitwise_and(0xFF).to_u64()
					packed1 = List.get(words, BlockOut.packed_litlen_at.plus_wrap(lit1)) ?? 0
					$bitbuf = $bitbuf.bitwise_or(packed1.bitwise_and(0xFFFF_FFFF).shl_wrap($bitcount.to_u8_wrap()))
					$bitcount = $bitcount.plus_wrap(packed1.shr_zf_wrap(32))
					lit2 = word.shr_zf_wrap(16).bitwise_and(0xFF).to_u64()
					packed2 = List.get(words, BlockOut.packed_litlen_at.plus_wrap(lit2)) ?? 0
					$bitbuf = $bitbuf.bitwise_or(packed2.bitwise_and(0xFFFF_FFFF).shl_wrap($bitcount.to_u8_wrap()))
					$bitcount = $bitcount.plus_wrap(packed2.shr_zf_wrap(32))
					lit3 = word.shr_zf_wrap(24).to_u64()
					packed3 = List.get(words, BlockOut.packed_litlen_at.plus_wrap(lit3)) ?? 0
					$bitbuf = $bitbuf.bitwise_or(packed3.bitwise_and(0xFFFF_FFFF).shl_wrap($bitcount.to_u8_wrap()))
					$bitcount = $bitcount.plus_wrap(packed3.shr_zf_wrap(32))
					$in_next = $in_next.plus_wrap(4)
					n = $bitcount.shr_zf_wrap(3)
					$out = match $bitbuf.append_le_bytes_to($out, n.to_u8_wrap()) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$bitbuf = $bitbuf.shr_zf_wrap(n.shl_wrap(3).to_u8_wrap())
					$bitcount = $bitcount.bitwise_and(7)
					$litrunlen = $litrunlen.minus_wrap(4)
				}
				if $litrunlen != 0 {
					lit0 = (List.get(input, $in_next) ?? 0).to_u64()
					packed0 = List.get(words, BlockOut.packed_litlen_at.plus_wrap(lit0)) ?? 0
					$bitbuf = $bitbuf.bitwise_or(packed0.bitwise_and(0xFFFF_FFFF).shl_wrap($bitcount.to_u8_wrap()))
					$bitcount = $bitcount.plus_wrap(packed0.shr_zf_wrap(32))
					$in_next = $in_next.plus_wrap(1)
					if $litrunlen >= 2 {
						lit1 = (List.get(input, $in_next) ?? 0).to_u64()
						packed1 = List.get(words, BlockOut.packed_litlen_at.plus_wrap(lit1)) ?? 0
						$bitbuf = $bitbuf.bitwise_or(packed1.bitwise_and(0xFFFF_FFFF).shl_wrap($bitcount.to_u8_wrap()))
						$bitcount = $bitcount.plus_wrap(packed1.shr_zf_wrap(32))
						$in_next = $in_next.plus_wrap(1)
						if $litrunlen >= 3 {
							lit2 = (List.get(input, $in_next) ?? 0).to_u64()
							packed2 = List.get(words, BlockOut.packed_litlen_at.plus_wrap(lit2)) ?? 0
							$bitbuf = $bitbuf.bitwise_or(packed2.bitwise_and(0xFFFF_FFFF).shl_wrap($bitcount.to_u8_wrap()))
							$bitcount = $bitcount.plus_wrap(packed2.shr_zf_wrap(32))
							$in_next = $in_next.plus_wrap(1)
						} else {}
					} else {}
					n = $bitcount.shr_zf_wrap(3)
					$out = match $bitbuf.append_le_bytes_to($out, n.to_u8_wrap()) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$bitbuf = $bitbuf.shr_zf_wrap(n.shl_wrap(3).to_u8_wrap())
					$bitcount = $bitcount.bitwise_and(7)
				} else {}

				if length == 0 {
					$writing = False
				} else {
					# A whole match fits between flushes as well: the length
					# codeword with its extra bits, the offset codeword, and the
					# extra offset bits come to at most 47 bits.
					offset = seq.offset.to_u64()
					offset_slot = seq.offset_slot.to_u64()
					packed_len = List.get(words, BlockOut.packed_lengths_at.plus_wrap(length)) ?? 0
					$bitbuf = $bitbuf.bitwise_or(packed_len.bitwise_and(0xFFFF_FFFF).shl_wrap($bitcount.to_u8_wrap()))
					$bitcount = $bitcount.plus_wrap(packed_len.shr_zf_wrap(32))
					packed_off = List.get(words, BlockOut.packed_offsets_at.plus_wrap(offset_slot)) ?? 0
					$bitbuf = $bitbuf.bitwise_or(packed_off.bitwise_and(0xFFFF).shl_wrap($bitcount.to_u8_wrap()))
					$bitcount = $bitcount.plus_wrap(packed_off.shr_zf_wrap(16).bitwise_and(0xFF))
					$bitbuf = $bitbuf.bitwise_or(offset.minus_wrap(packed_off.shr_zf_wrap(32)).shl_wrap($bitcount.to_u8_wrap()))
					$bitcount = $bitcount.plus_wrap(packed_off.shr_zf_wrap(24).bitwise_and(0xFF))
					n = $bitcount.shr_zf_wrap(3)
					$out = match $bitbuf.append_le_bytes_to($out, n.to_u8_wrap()) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$bitbuf = $bitbuf.shr_zf_wrap(n.shl_wrap(3).to_u8_wrap())
					$bitcount = $bitcount.bitwise_and(7)
					$in_next = $in_next.plus_wrap(length)
					$seq_idx = $seq_idx.plus_wrap(1)
				}
			}

			# End of block.
			$bitbuf = $bitbuf.bitwise_or((List.get(w_litlen_codewords, DeflateTables.end_of_block) ?? 0).to_u64().shl_wrap($bitcount.to_u8_wrap()))
			$bitcount = $bitcount + (List.get(w_litlen_lens, DeflateTables.end_of_block) ?? 0).to_u64()
			n = $bitcount.shr_zf_wrap(3)
			$out = match $bitbuf.append_le_bytes_to($out, n.to_u8_wrap()) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$bitbuf = $bitbuf.shr_zf_wrap(n.shl_wrap(3).to_u8_wrap())
			$bitcount = $bitcount.bitwise_and(7)

			Ok({
				out: $out,
				bitbuf: $bitbuf,
				bitcount: $bitcount,
				seqs,
				items,
				scratch: {
					words,
					precode_freqs,
					precode_lens,
					precode_codewords,
				},
			})
		}
	}
}
