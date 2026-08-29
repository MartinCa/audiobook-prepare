#!/usr/bin/env bats

setup() {
	source "$BATS_TEST_DIRNAME/../lib.sh"
	workdir=$(mktemp -d)
}

teardown() {
	rm -rf "$workdir"
}

# --- log ---------------------------------------------------------------

@test "log: prefixes message with a timestamp" {
	run log "hello world"
	[ "$status" -eq 0 ]
	[[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\ hello\ world$ ]]
}

# --- duration_to_seconds ---------------------------------------------------

@test "duration_to_seconds: bare number is seconds" {
	run duration_to_seconds "120"
	[ "$status" -eq 0 ]
	[ "$output" = "120" ]
}

@test "duration_to_seconds: s suffix is seconds" {
	run duration_to_seconds "120s"
	[ "$status" -eq 0 ]
	[ "$output" = "120" ]
}

@test "duration_to_seconds: m suffix is minutes" {
	run duration_to_seconds "2m"
	[ "$status" -eq 0 ]
	[ "$output" = "120" ]
}

@test "duration_to_seconds: h suffix is hours" {
	run duration_to_seconds "1h"
	[ "$status" -eq 0 ]
	[ "$output" = "3600" ]
}

@test "duration_to_seconds: uppercase suffix works" {
	run duration_to_seconds "2M"
	[ "$status" -eq 0 ]
	[ "$output" = "120" ]
}

@test "duration_to_seconds: zero is valid" {
	run duration_to_seconds "0"
	[ "$status" -eq 0 ]
	[ "$output" = "0" ]
}

@test "duration_to_seconds: rejects double suffix" {
	run duration_to_seconds "2mm"
	[ "$status" -eq 1 ]
}

@test "duration_to_seconds: rejects suffix with no number" {
	run duration_to_seconds "m"
	[ "$status" -eq 1 ]
}

@test "duration_to_seconds: rejects non-numeric input" {
	run duration_to_seconds "abc"
	[ "$status" -eq 1 ]
}

@test "duration_to_seconds: rejects negative numbers" {
	run duration_to_seconds "-5"
	[ "$status" -eq 1 ]
}

@test "duration_to_seconds: rejects empty input" {
	run duration_to_seconds ""
	[ "$status" -eq 1 ]
}

# --- format_duration --------------------------------------------------------

@test "format_duration: renders hours, minutes and seconds" {
	run format_duration 37425000
	[ "$status" -eq 0 ]
	[ "$output" = "10:23:45" ]
}

@test "format_duration: pads single digits" {
	run format_duration 5000
	[ "$status" -eq 0 ]
	[ "$output" = "00:00:05" ]
}

@test "format_duration: truncates sub-second remainders" {
	run format_duration 1999
	[ "$status" -eq 0 ]
	[ "$output" = "00:00:01" ]
}

@test "format_duration: rejects non-numeric input" {
	run format_duration "N/A"
	[ "$status" -eq 1 ]
}

# --- duration_is_plausible --------------------------------------------------

@test "duration_is_plausible: identical durations match" {
	run duration_is_plausible 36000000 36000000
	[ "$status" -eq 0 ]
}

@test "duration_is_plausible: encoder padding on a short file is within the floor" {
	run duration_is_plausible 30000 31500
	[ "$status" -eq 0 ]
}

@test "duration_is_plausible: drift of exactly 0.5% on a long book is accepted" {
	# 10 hours, 3 minutes of drift
	run duration_is_plausible 36000000 35820000
	[ "$status" -eq 0 ]
}

@test "duration_is_plausible: a dropped 8 minute file on a 10 hour book is rejected" {
	run duration_is_plausible 36000000 35520000
	[ "$status" -eq 1 ]
}

@test "duration_is_plausible: rejects a file that is too long as well as too short" {
	run duration_is_plausible 36000000 36480000
	[ "$status" -eq 1 ]
}

@test "duration_is_plausible: rejects non-numeric expected" {
	run duration_is_plausible "N/A" 36000000
	[ "$status" -eq 1 ]
}

@test "duration_is_plausible: rejects empty actual" {
	run duration_is_plausible 36000000 ""
	[ "$status" -eq 1 ]
}

# --- last_progress_ms -------------------------------------------------------

@test "last_progress_ms: reads out_time_us from a progress block" {
	printf 'bitrate=64.0kbits/s\nout_time_us=37425000000\nout_time_ms=37425000000\nprogress=end\n' \
		>"$workdir/progress"
	run last_progress_ms "$workdir/progress"
	[ "$status" -eq 0 ]
	[ "$output" = "37425000" ]
}

@test "last_progress_ms: takes the last block when several are appended" {
	printf 'out_time_us=1000000\nprogress=continue\nout_time_us=9000000\nprogress=end\n' \
		>"$workdir/progress"
	run last_progress_ms "$workdir/progress"
	[ "$status" -eq 0 ]
	[ "$output" = "9000" ]
}

@test "last_progress_ms: ignores N/A blocks written before output starts" {
	printf 'out_time_us=N/A\nprogress=continue\nout_time_us=4000000\nprogress=end\n' \
		>"$workdir/progress"
	run last_progress_ms "$workdir/progress"
	[ "$status" -eq 0 ]
	[ "$output" = "4000" ]
}

@test "last_progress_ms: falls back to out_time_ms, which is also microseconds" {
	printf 'out_time_ms=4000000\nprogress=end\n' >"$workdir/progress"
	run last_progress_ms "$workdir/progress"
	[ "$status" -eq 0 ]
	[ "$output" = "4000" ]
}

@test "last_progress_ms: fails on a progress file with no usable value" {
	printf 'progress=end\n' >"$workdir/progress"
	run last_progress_ms "$workdir/progress"
	[ "$status" -eq 1 ]
	[ -z "$output" ]
}

@test "last_progress_ms: fails when the progress file is missing" {
	run last_progress_ms "$workdir/does-not-exist"
	[ "$status" -eq 1 ]
}

# --- is_media_file ----------------------------------------------------------

@test "is_media_file: recognizes known extensions" {
	touch "$workdir/book.mp3"
	run is_media_file "$workdir/book.mp3"
	[ "$status" -eq 0 ]
}

@test "is_media_file: rejects unknown extensions" {
	touch "$workdir/book.txt"
	run is_media_file "$workdir/book.txt"
	[ "$status" -eq 1 ]
}

@test "is_media_file: rejects directories" {
	mkdir "$workdir/book"
	run is_media_file "$workdir/book"
	[ "$status" -eq 1 ]
}

# --- is_stable ----------------------------------------------------------

@test "is_stable: fresh file is not stable" {
	stabletime=120
	touch "$workdir/fresh.mp3"
	run is_stable "$workdir/fresh.mp3"
	[ "$status" -eq 1 ]
}

@test "is_stable: old file is stable" {
	stabletime=120
	touch -d "-10 minutes" "$workdir/old.mp3"
	run is_stable "$workdir/old.mp3"
	[ "$status" -eq 0 ]
}

@test "is_stable: directory with a fresh file inside is not stable" {
	stabletime=120
	mkdir "$workdir/book"
	touch -d "-10 minutes" "$workdir/book/old.mp3"
	touch -d "-10 minutes" "$workdir/book"
	touch "$workdir/book/fresh.mp3"
	run is_stable "$workdir/book"
	[ "$status" -eq 1 ]
}

@test "is_stable: directory with only old files is stable" {
	stabletime=120
	mkdir "$workdir/book"
	touch -d "-10 minutes" "$workdir/book/a.mp3"
	touch -d "-10 minutes" "$workdir/book/b.mp3"
	touch -d "-10 minutes" "$workdir/book"
	run is_stable "$workdir/book"
	[ "$status" -eq 0 ]
}

@test "is_stable: stabletime of 0 always reports stable" {
	stabletime=0
	touch "$workdir/fresh.mp3"
	run is_stable "$workdir/fresh.mp3"
	[ "$status" -eq 0 ]
}

@test "is_stable: missing path is not stable" {
	stabletime=120
	run is_stable "$workdir/does-not-exist.mp3"
	[ "$status" -eq 1 ]
}

@test "is_stable: future mtime (clock skew) is not stable" {
	stabletime=120
	touch -d "+1 hour" "$workdir/future.mp3"
	run is_stable "$workdir/future.mp3"
	[ "$status" -eq 1 ]
}
