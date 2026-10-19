## Deterministic text-like corpus for the interop tests.
##
## tests/harness.roc calls `generate` with a fixed seed and length to build the
## same bytes on every run, so gzip interop is always checked against an
## identical, in-memory corpus.

TextGen := [].{

	## Generate `target` bytes (or slightly more, always ending on a word
	## boundary) of word-based text from a deterministic LCG.
	generate : U64, U64 -> List(U8)
	generate = |seed, target|
		gen_text(List.with_capacity(target + 32), seed, target, words({}))
}

# Word list built once per generate call and threaded as an argument: in the
# pinned compiler, reading a module-level list constant re-materializes it on
# every access, so hot loops must not touch one.
words : {} -> List(List(U8))
words = |{}|
	[
		"the",
		"quick",
		"brown",
		"fox",
		"jumps",
		"over",
		"lazy",
		"dog",
		"compression",
		"works",
		"best",
		"when",
		"text",
		"repeats",
		"itself",
		"in",
		"various",
		"ways",
		"and",
		"places",
		"throughout",
		"a",
		"document",
		"with",
		"some",
		"longer",
		"words",
		"appearing",
		"occasionally",
		"like",
		"internationalization",
		"server",
		"request",
		"response",
		"handler",
		"buffer",
		"stream",
		"packet",
		"header",
		"payload",
	].map(|w| w.to_utf8())

gen_text : List(U8), U64, U64, List(List(U8)) -> List(U8)
gen_text = |acc, state, target, word_list|
	if acc.len() >= target {
		acc
	} else {
		next = (state * 1103515245 + 12345).bitwise_and(0x7FFFFFFF)
		word = word_list.get(next.shr_wrap(16) % 40) ?? []
		gen_text(append_word(acc, word, 0), next, target, word_list)
	}

append_word : List(U8), List(U8), U64 -> List(U8)
append_word = |acc, word, index|
	if index >= word.len() {
		acc.append(32)
	} else {
		append_word(acc.append(word.get(index) ?? 32), word, index + 1)
	}

expect TextGen.generate(42, 100) == TextGen.generate(42, 100)

expect TextGen.generate(42, 100).len() >= 100

# Ends on a word boundary (trailing space)
expect TextGen.generate(42, 100).last() == Ok(32)
