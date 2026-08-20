#!/usr/bin/env bats

setup() {
	source "$BATS_TEST_DIRNAME/../lib.sh"
	workdir=$(mktemp -d)
}

teardown() {
	rm -rf "$workdir"
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
