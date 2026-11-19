## RFC 5424 levels, in increasing severity.
LogLevel := [Debug, Info, Notice, Warning, Error, Critical, Alert, Emergency].{
	is_eq : _

	## The wire name: `debug`, `info`, `notice`, `warning`, `error`, `critical`, `alert`, `emergency`.
	to_str : LogLevel -> Str
	to_str = |l| match l {
		Debug => "debug"
		Info => "info"
		Notice => "notice"
		Warning => "warning"
		Error => "error"
		Critical => "critical"
		Alert => "alert"
		Emergency => "emergency"
	}

	## Parses a wire name (exact, lower case).
	from_str : Str -> Try(LogLevel, [UnknownLevel])
	from_str = |s| match s {
		"debug" => Ok(Debug)
		"info" => Ok(Info)
		"notice" => Ok(Notice)
		"warning" => Ok(Warning)
		"error" => Ok(Error)
		"critical" => Ok(Critical)
		"alert" => Ok(Alert)
		"emergency" => Ok(Emergency)
		_ => Err(UnknownLevel)
	}

	## 0 for Debug to 7 for Emergency.
	severity : LogLevel -> U8
	severity = |l| match l {
		Debug => 0
		Info => 1
		Notice => 2
		Warning => 3
		Error => 4
		Critical => 5
		Alert => 6
		Emergency => 7
	}

	## True when `l` is as severe as `minimum` or more: a message at `l` passes a session level of `minimum`.
	is_at_least : LogLevel, LogLevel -> Bool
	is_at_least = |l, minimum| severity(l) >= severity(minimum)

	## Every level, least severe first.
	all : List(LogLevel)
	all = [Debug, Info, Notice, Warning, Error, Critical, Alert, Emergency]
}
