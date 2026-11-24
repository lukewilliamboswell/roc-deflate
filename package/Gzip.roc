import Deflate
import Inflate
import Crc32

## The gzip file format (RFC 1952) around this package's DEFLATE streams.
##
## `decompress` reads what `gzip` and `tar -z` write, a `.gz`, `.tgz` or
## `.crate` file, checking every member's CRC-32 and size. `compress` writes
## one member the way libdeflate's `libdeflate_gzip_compress` does, so its
## output is the same bytes as `libdeflate-gzip -c` at every level from 1
## to 12.

Gzip := [].{

	## Errors that can occur when decompressing gzip data.
	##
	## The header's: `NotGzip` means a member does not start with the gzip magic
	## bytes, `UnsupportedMethod` that it names a compression method other than
	## DEFLATE, the only one RFC 1952 defines, `ReservedFlags` that it sets a flag
	## bit RFC 1952 reserves, and `HeaderCrcMismatch` that the header's own CRC-16
	## does not match it.
	##
	## The DEFLATE stream's, as `Deflate.decompress` reports them: `CorruptData`,
	## `UnexpectedEnd` and `OutputLimitExceeded`. `UnexpectedEnd` also means the
	## input ended inside a header or a trailer, so any truncated gzip file, an
	## empty input included, reports it.
	##
	## The trailer's: `CrcMismatch` means the CRC-32 of a member's output is not
	## the one its trailer gives, and `SizeMismatch` that the output's length,
	## modulo 2^32, is not the trailer's.
	##
	## `TrailingData` means bytes follow the last member that do not start
	## another.
	GzipError : [
		NotGzip,
		UnsupportedMethod,
		ReservedFlags,
		HeaderCrcMismatch,
		CorruptData,
		UnexpectedEnd,
		OutputLimitExceeded,
		CrcMismatch,
		SizeMismatch,
		TrailingData,
	]

	## Decompress gzip data, checking each member's CRC-32 and size, within
	## `bounds`.
	##
	## A gzip file may hold several members one after another, and their
	## output is concatenated, as `gunzip` does. The bound is on the whole
	## output, all members together. Bytes after a member that do not begin
	## with the gzip magic bytes are `TrailingData`, zeros included: nothing
	## after the last member is ignored, so a file that decodes is all
	## accounted for.
	##
	## The header's optional fields, the extra field, the file name and the
	## comment, are read past and not returned, and its modification time,
	## extra flags and operating system are not checked.
	##
	## Without a declared size, the output starts with room for the size the
	## last four bytes give, which is the whole output's for a file of one
	## member, if that fits `max_output` and is no more than DEFLATE can
	## expand the input to, and otherwise with room for three times the input,
	## as `Deflate.decompress` does. Either way it is a hint, like a declared
	## size: the output grows if it is wrong, and the trailers are checked
	## all the same.
	decompress : List(U8), Deflate.Bounds -> Try(List(U8), Gzip.GzipError)
	decompress = |input, bounds| {
		in_len = List.len(input)
		max_output = bounds.max_output
		reserve = match bounds.expected_size {
			Declared(n) => n
			Unknown => size_hint(input, max_output)
		}
		var $scratch = Inflate.new_scratch()
		var $out = []
		var $reserve = reserve
		var $pos = 0.U64
		var $more = True
		while $more {
			body = member_body(input, $pos)?
			member_start = List.len($out)
			done = Inflate.inflate_from($scratch, input, body, $out, max_output - member_start, $reserve)
			inflated = done.output?
			$scratch = done.scratch
			$out = inflated.out
			$reserve = 0
			member_len = List.len($out) - member_start
			if inflated.in_end + 8 > in_len {
				return Err(UnexpectedEnd)
			} else {}
			if Crc32.update(0, $out, member_start, member_len) != le32(input, inflated.in_end) {
				return Err(CrcMismatch)
			} else {}
			if member_len.to_u32_wrap() != le32(input, inflated.in_end + 4) {
				return Err(SizeMismatch)
			} else {}
			$pos = inflated.in_end + 8
			if $pos == in_len {
				$more = False
			} else if List.get(input, $pos) != Ok(0x1F) or List.get(input, $pos + 1) != Ok(0x8B) {
				return Err(TrailingData)
			} else {}
		}
		Ok($out)
	}

	## Compress bytes into a gzip file of one member, at the given level.
	##
	## The header is the one libdeflate writes: no file name or other
	## optional field, a modification time of 0, the extra flags its level
	## calls for (4 below level 2, 2 from level 8, 0 between), and 255, an
	## unknown operating system. The same input and level always give the
	## same bytes, the same as `libdeflate-gzip -c` writes.
	##
	## This never fails. It crashes only on a bug in this package.
	compress : List(U8), Deflate.Level -> List(U8)
	compress = |input, level| {
		n = level.to_u64()
		xfl = if n < 2 { 4 } else if n >= 8 { 2 } else { 0 }
		header = List.with_capacity(Deflate.compress_bound(List.len(input)).plus_saturated(18))
			.concat([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, xfl, 255])
		stream = Deflate.compress_into(input, level, header)
		with_crc = append_le32(stream, Crc32.update(0, input, 0, List.len(input)))
		append_le32(with_crc, List.len(input).to_u32_wrap())
	}
}

# Gzip header flags (RFC 1952, section 2.3.1). FTEXT, bit 0, is only a hint
# about the content and changes nothing about how a member is read.
fhcrc : U8
fhcrc = 0x02

fextra : U8
fextra = 0x04

fname : U8
fname = 0x08

fcomment : U8
fcomment = 0x10

reserved_flags : U8
reserved_flags = 0xE0

# The index where the DEFLATE stream of the member starting at `start`
# begins, past its header and the header's optional fields.
member_body : List(U8), U64 -> Try(U64, [NotGzip, UnsupportedMethod, ReservedFlags, HeaderCrcMismatch, UnexpectedEnd])
member_body = |input, start| {
	in_len = List.len(input)
	byte = |i| List.get(input, start + i).map_err(|_| UnexpectedEnd)
	if byte(0)? != 0x1F or byte(1)? != 0x8B {
		return Err(NotGzip)
	} else {}
	if byte(2)? != 8 {
		return Err(UnsupportedMethod)
	} else {}
	flags = byte(3)?
	if flags.bitwise_and(reserved_flags) != 0 {
		return Err(ReservedFlags)
	} else {}
	# MTIME (4 bytes), XFL and OS come before the optional fields.
	if in_len < start + 10 {
		return Err(UnexpectedEnd)
	} else {}
	var $pos = start + 10
	if flags.bitwise_and(fextra) != 0 {
		if in_len < $pos + 2 {
			return Err(UnexpectedEnd)
		} else {}
		xlen = (List.get(input, $pos) ?? 0).to_u64() + (List.get(input, $pos + 1) ?? 0).to_u64().shl_wrap(8)
		$pos = $pos + 2 + xlen
		if in_len < $pos {
			return Err(UnexpectedEnd)
		} else {}
	} else {}
	if flags.bitwise_and(fname) != 0 {
		$pos = past_zero(input, $pos)?
	} else {}
	if flags.bitwise_and(fcomment) != 0 {
		$pos = past_zero(input, $pos)?
	} else {}
	if flags.bitwise_and(fhcrc) != 0 {
		if in_len < $pos + 2 {
			return Err(UnexpectedEnd)
		} else {}
		# The low 16 bits of the CRC-32 of every header byte before it.
		stored = (List.get(input, $pos) ?? 0).to_u32() + (List.get(input, $pos + 1) ?? 0).to_u32().shl_wrap(8)
		if Crc32.update(0, input, start, $pos - start).bitwise_and(0xFFFF) != stored {
			return Err(HeaderCrcMismatch)
		} else {}
		$pos = $pos + 2
	} else {}
	Ok($pos)
}

# The index after the zero byte that ends the string starting at `pos`.
past_zero : List(U8), U64 -> Try(U64, [UnexpectedEnd])
past_zero = |input, pos| {
	var $i = pos
	while $i < List.len(input) {
		if List.get(input, $i) == Ok(0) {
			return Ok($i + 1)
		} else {}
		$i = $i + 1
	}
	Err(UnexpectedEnd)
}

# The little-endian U32 at `at`, which the caller has checked is in bounds.
le32 : List(U8), U64 -> U32
le32 = |bytes, at| {
	b = |i| (List.get(bytes, at + i) ?? 0).to_u32()
	b(0).bitwise_or(b(1).shl_wrap(8)).bitwise_or(b(2).shl_wrap(16)).bitwise_or(b(3).shl_wrap(24))
}

append_le32 : List(U8), U32 -> List(U8)
append_le32 = |bytes, value|
	bytes
		.append(value.to_u8_wrap())
		.append(value.shr_zf_wrap(8).to_u8_wrap())
		.append(value.shr_zf_wrap(16).to_u8_wrap())
		.append(value.shr_zf_wrap(24).to_u8_wrap())

# How much output to reserve when the caller declared no size: the size the
# last four bytes give, when it fits `max_output` and DEFLATE could expand
# the input that far (about 1032:1 at most), and otherwise three times the
# input, as `Deflate.decompress` reserves.
size_hint : List(U8), U64 -> U64
size_hint = |input, max_output| {
	in_len = List.len(input)
	fallback = in_len.min(U64.highest // 3) * 3
	if in_len < 18 {
		fallback
	} else {
		trailer_size = le32(input, in_len - 4).to_u64()
		if trailer_size <= max_output and trailer_size <= in_len.min(U64.highest // 1032) * 1032 {
			trailer_size
		} else {
			fallback
		}
	}
}

# The tests here are hand-built members, so they pin the reader to RFC 1952
# rather than to this package's writer. tests/harness.roc compares both
# directions with real gzip and libdeflate-gzip.

# A final stored block of "Hello", and its trailer: CRC-32 0xF7D18982 and
# size 5, both little-endian.
hello_stream : List(U8)
hello_stream = [0x01, 0x05, 0x00, 0xFA, 0xFF, 0x48, 0x65, 0x6C, 0x6C, 0x6F]

hello_trailer : List(U8)
hello_trailer = [0x82, 0x89, 0xD1, 0xF7, 0x05, 0x00, 0x00, 0x00]

# A header with no flags set, from Unix (OS 3).
plain_header : List(U8)
plain_header = [0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3]

hello : List(U8)
hello = plain_header.concat(hello_stream).concat(hello_trailer)

# A header with every flag RFC 1952 defines: FTEXT, an extra field of one
# four-byte subfield, a file name, a comment, and the header CRC, 0x3A32.
full_header : List(U8)
full_header = [0x1F, 0x8B, 8, 0x1F, 0, 0, 0, 0, 0, 3]
	.concat([4, 0, 0x41, 0x42, 0, 0])
	.concat("hello.txt".to_utf8()).concat([0])
	.concat("a comment".to_utf8()).concat([0])
	.concat([0x32, 0x3A])

full_hello : List(U8)
full_hello = full_header.concat(hello_stream).concat(hello_trailer)

# A header with these flags and these optional fields after its first ten
# bytes.
header_with : U8, List(U8) -> List(U8)
header_with = |flags, fields| [0x1F, 0x8B, 8, flags, 0, 0, 0, 0, 0, 3].concat(fields)

expect Gzip.decompress(hello, {}) == Ok("Hello".to_utf8())

expect Gzip.decompress(full_hello, {}) == Ok("Hello".to_utf8())

# Each optional field on its own, and FTEXT, which changes nothing.
expect Gzip.decompress(header_with(0x01, []).concat(hello_stream).concat(hello_trailer), {}) == Ok("Hello".to_utf8())

expect Gzip.decompress(header_with(0x04, [4, 0, 0x41, 0x42, 0, 0]).concat(hello_stream).concat(hello_trailer), {}) == Ok("Hello".to_utf8())

expect Gzip.decompress(header_with(0x04, [0, 0]).concat(hello_stream).concat(hello_trailer), {}) == Ok("Hello".to_utf8())

expect Gzip.decompress(header_with(0x08, "hello.txt".to_utf8().append(0)).concat(hello_stream).concat(hello_trailer), {}) == Ok("Hello".to_utf8())

expect Gzip.decompress(header_with(0x08, [0]).concat(hello_stream).concat(hello_trailer), {}) == Ok("Hello".to_utf8())

expect Gzip.decompress(header_with(0x10, "a comment".to_utf8().append(0)).concat(hello_stream).concat(hello_trailer), {}) == Ok("Hello".to_utf8())

# The header CRC of the ten fixed bytes of plain_header with FHCRC set.
expect Gzip.decompress(header_with(0x02, [0xA7, 0x77]).concat(hello_stream).concat(hello_trailer), {}) == Ok("Hello".to_utf8())

expect Gzip.decompress(header_with(0x02, [0xA8, 0x77]).concat(hello_stream).concat(hello_trailer), {}) == Err(HeaderCrcMismatch)

# The header CRC covers the optional fields too: change one byte of the
# file name and it no longer matches.
expect Gzip.decompress(List.set(full_hello, 20, 0x58) ?? [], {}) == Err(HeaderCrcMismatch)

# Each of the three reserved flag bits.
expect [0x20, 0x40, 0x80, 0xFF].all(|flags| Gzip.decompress(header_with(flags, []).concat(hello_stream).concat(hello_trailer), {}) == Err(ReservedFlags))

# The magic bytes, and the only compression method.
expect Gzip.decompress([0x1F, 0x8C].concat(hello.drop_first(2)), {}) == Err(NotGzip)

expect Gzip.decompress([0x1E].concat(hello.drop_first(1)), {}) == Err(NotGzip)

expect Gzip.decompress(hello_stream, {}) == Err(NotGzip)

expect Gzip.decompress(List.set(hello, 2, 7) ?? [], {}) == Err(UnsupportedMethod)

# Every truncation of a member, in its header's fixed bytes, any optional
# field, the DEFLATE stream or the trailer, the empty input included.
expect {
	var $ok = True
	for member in [hello, full_hello] {
		var $len = 0.U64
		while $len < List.len(member) {
			if Gzip.decompress(List.sublist(member, { start: 0, len: $len }), {}) != Err(UnexpectedEnd) {
				$ok = False
			} else {}
			$len = $len + 1
		}
	}
	$ok
}

# An extra field longer than what follows it, and a name with no end.
expect Gzip.decompress(header_with(0x04, [0xFF, 0xFF]).concat(hello_stream).concat(hello_trailer), {}) == Err(UnexpectedEnd)

expect Gzip.decompress(header_with(0x08, "hello.txt".to_utf8()), {}) == Err(UnexpectedEnd)

# The DEFLATE stream's own errors come through unchanged.
expect Gzip.decompress(plain_header.concat([0x01, 0x05, 0x00, 0xFB, 0xFF, 0x48, 0x65, 0x6C, 0x6C, 0x6F]).concat(hello_trailer), {}) == Err(CorruptData)

expect Gzip.decompress(plain_header.concat([0x07]).concat(hello_trailer), {}) == Err(CorruptData)

# The trailer: any change to the CRC-32 or the size is caught, and the CRC is
# checked first.
expect {
	at_crc = List.len(hello) - 8
	List.repeat(0, 8).map_with_index(|_, i| i).all(|i| {
		byte = List.get(hello, at_crc + i) ?? 0
		changed = List.set(hello, at_crc + i, byte.bitwise_xor(0x10)) ?? []
		expected = if i < 4 { Err(CrcMismatch) } else { Err(SizeMismatch) }
		Gzip.decompress(changed, {}) == expected
	})
}

expect Gzip.decompress(plain_header.concat(hello_stream).concat([0, 0, 0, 0, 0, 0, 0, 0]), {}) == Err(CrcMismatch)

# The bound: exactly the output's length decodes and one byte fewer does not.
expect Gzip.decompress(hello, { max_output: 5 }) == Ok("Hello".to_utf8())

expect Gzip.decompress(hello, { max_output: 4 }) == Err(OutputLimitExceeded)

expect Gzip.decompress(hello, { max_output: 0 }) == Err(OutputLimitExceeded)

# Members one after another decode to their outputs one after another, as
# gunzip gives them, and the bound counts all of them together.
expect Gzip.decompress(hello.concat(full_hello).concat(hello), {}) == Ok("HelloHelloHello".to_utf8())

expect Gzip.decompress(hello.concat(hello), { max_output: 10 }) == Ok("HelloHello".to_utf8())

expect Gzip.decompress(hello.concat(hello), { max_output: 9 }) == Err(OutputLimitExceeded)

expect Gzip.decompress(hello.concat(hello), { max_output: 5 }) == Err(OutputLimitExceeded)

# A later member is checked as fully as the first.
expect Gzip.decompress(hello.concat(List.set(hello, 2, 7) ?? []), {}) == Err(UnsupportedMethod)

expect Gzip.decompress(hello.concat(hello.drop_last(1)), {}) == Err(UnexpectedEnd)

expect Gzip.decompress(hello.concat(plain_header).concat(hello_stream).concat([0, 0, 0, 0, 5, 0, 0, 0]), {}) == Err(CrcMismatch)

# A member's stream cannot refer back into an earlier member's output: a
# fixed block whose first symbol is a match, length 3 at distance 3.
expect Gzip.decompress(hello.concat(plain_header).concat([0x03, 0x22, 0x00]).concat(List.repeat(0, 8)), {}) == Err(CorruptData)

# Bytes after the last member that do not start another, zeros included.
expect Gzip.decompress(hello.concat([0]), {}) == Err(TrailingData)

expect Gzip.decompress(hello.concat(List.repeat(0, 512)), {}) == Err(TrailingData)

expect Gzip.decompress(hello.concat([0x1F]), {}) == Err(TrailingData)

expect Gzip.decompress(hello.concat([0x1F, 0x8C]), {}) == Err(TrailingData)

# Two magic bytes start a member, so stopping there is a truncation.
expect Gzip.decompress(hello.concat([0x1F, 0x8B]), {}) == Err(UnexpectedEnd)

# The writer: libdeflate's header, the stream `Deflate.compress` gives, and
# the trailer, at every level, and it reads back.
expect {
	text = "the cat, the cow, the crow, then the cricket saw the cow again and again".to_utf8()
	Deflate.Level.all.all(|level| {
		n = level.to_u64()
		xfl = if n < 2 { 4 } else if n >= 8 { 2 } else { 0 }
		gz = Gzip.compress(text, level)
		List.sublist(gz, { start: 0, len: 10 }) == [0x1F, 0x8B, 8, 0, 0, 0, 0, 0, xfl, 255]
			and List.sublist(gz, { start: 10, len: List.len(gz) - 18 }) == Deflate.compress(text, level)
			and List.sublist(gz, { start: List.len(gz) - 4, len: 4 }) == [72, 0, 0, 0]
			and Gzip.decompress(gz, {}) == Ok(text)
	})
}

expect Gzip.compress("Hello".to_utf8(), 0) == [0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 4, 255].concat(hello_stream).concat(hello_trailer)

expect Gzip.decompress(Gzip.compress([], 6), {}) == Ok([])

expect Gzip.decompress(Gzip.compress([], 6).concat(hello).concat(Gzip.compress([], 1)), {}) == Ok("Hello".to_utf8())

# The writer fills the trailer for a long input, through every block type.
expect {
	text = "the cat, the cow, the crow, then the cricket saw the cow again and again".to_utf8()
	long = List.join(List.repeat(text, 1000)).concat(List.repeat(0, 70_000))
	[0, 1, 6, 12].all(|level| Gzip.decompress(Gzip.compress(long, level), {}) == Ok(long))
}

# With no declared size, a single member's trailer size is the reservation,
# so a truthful one decodes in one allocation.
expect {
	text = "the cat, the cow, the crow, then the cricket saw the cow again and again".to_utf8()
	original = List.join(List.repeat(text, 300))
	n = List.len(original)
	match Gzip.decompress(Gzip.compress(original, 6), {}) {
		Ok(out) => out == original and List.capacity(out) == n + Inflate.copy_scratch
		Err(_) => False
	}
}

# A trailer size beyond the bound, or beyond what DEFLATE can expand the
# input to, reserves no more than three times the input, and the member
# still fails its size check. A declared size overrides it.
expect {
	gz = plain_header.concat(hello_stream).concat([0x82, 0x89, 0xD1, 0xF7, 0xFF, 0xFF, 0xFF, 0x7F])
	size_hint(gz, 1_073_741_824) == 3 * List.len(gz)
		and Gzip.decompress(gz, {}) == Err(SizeMismatch)
		and size_hint(hello, 4) == 3 * List.len(hello)
		and size_hint(hello, 5) == 5
}

expect {
	match Gzip.decompress(hello, { expected_size: Declared(1000) }) {
		Ok(out) => out == "Hello".to_utf8() and List.capacity(out) >= 1000
		Err(_) => False
	}
}
