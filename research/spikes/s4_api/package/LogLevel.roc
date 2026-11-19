## RFC 5424 levels, in increasing severity.
LogLevel := [Debug, Info, Notice, Warning, Error, Critical, Alert, Emergency].{
	is_eq : _

	to_str : LogLevel -> Str
	to_str = |_l| crash "unimplemented"

	from_str : Str -> Try(LogLevel, [UnknownLevel])
	from_str = |_s| crash "unimplemented"

	## 0 for Debug to 7 for Emergency.
	severity : LogLevel -> U8
	severity = |_l| crash "unimplemented"
}
