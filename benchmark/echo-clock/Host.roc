Host := [].{

	## Print a UTF-8 string followed by a newline. Failure exits the process.
	echo! : Str => {}

	## Monotonic nanoseconds from an unspecified origin; use differences only.
	## This is elapsed time, not CPU cycles or Unix time. Failure exits the process.
	now! : () => U64
}
