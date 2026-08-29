#!/bin/bash
# Sourceable helper functions shared by process_mp3merge.sh and tests/lib.bats.
# Keep this file free of side effects (no cd/mkdir/loops) so it can be
# sourced safely in isolation.

# Print $* to stdout prefixed with a self-contained timestamp, independent
# of whatever timestamp (if any) an external log collector/viewer adds.
log() {
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

# Convert a duration such as "90", "90s", "2m" or "1h" to whole seconds.
# Outputs nothing and returns 1 if the value cannot be understood.
duration_to_seconds() {
	local value="$1"
	local number="${value%[smhSMH]}"
	local unit

	case "$number" in
	'' | *[!0-9]*) return 1 ;;
	esac

	unit="${value#"$number"}"

	case "$unit" in
	'' | s | S) echo "$number" ;;
	m | M) echo $((number * 60)) ;;
	h | H) echo $((number * 3600)) ;;
	*) return 1 ;;
	esac
}

# Render whole milliseconds as HH:MM:SS.
# Outputs nothing and returns 1 if the value is not a whole number.
format_duration() {
	local ms="$1"
	local total

	case "$ms" in
	'' | *[!0-9]*) return 1 ;;
	esac

	total=$((ms / 1000))
	printf '%02d:%02d:%02d\n' \
		$((total / 3600)) $((total % 3600 / 60)) $((total % 60))
}

# Returns 0 when two durations in milliseconds are close enough to be the same
# audio. Encoder priming/padding and container rounding shift a duration by a
# fraction of a second, so allow 0.5% with a 2 second floor; that still rejects
# a merge that lost a whole source file. Returns 1 on non-numeric input.
duration_is_plausible() {
	local expected="$1"
	local actual="$2"
	local difference tolerance

	case "$expected" in
	'' | *[!0-9]*) return 1 ;;
	esac
	case "$actual" in
	'' | *[!0-9]*) return 1 ;;
	esac

	if [ "$actual" -ge "$expected" ]; then
		difference=$((actual - expected))
	else
		difference=$((expected - actual))
	fi

	tolerance=$((expected / 200))
	if [ "$tolerance" -lt 2000 ]; then
		tolerance=2000
	fi

	[ "$difference" -le "$tolerance" ]
}

# Whole milliseconds of output reported by the last progress block ffmpeg
# wrote to $1 (see `ffmpeg -progress`). Outputs nothing and returns 1 if the
# file holds no usable value.
last_progress_ms() {
	local file="$1"
	local microseconds

	if [ ! -r "$file" ]; then
		return 1
	fi

	# ffmpeg reports microseconds in out_time_us and, despite its name, in
	# out_time_ms too. Prefer the honestly named field and fall back for
	# builds that only emit the other. Blocks written before any output has
	# been produced carry N/A, so only whole numbers are considered.
	microseconds=$(grep -E '^out_time_us=[0-9]+$' "$file" | tail -n 1 | cut -d= -f2)

	if [ -z "$microseconds" ]; then
		microseconds=$(grep -E '^out_time_ms=[0-9]+$' "$file" | tail -n 1 | cut -d= -f2)
	fi

	if [ -z "$microseconds" ]; then
		return 1
	fi

	echo $((microseconds / 1000))
}

is_media_file() {
	if [ ! -f "$1" ]; then
		return 1
	fi

	case "${1: -4}" in
	.m4b | .mp3 | .mp4 | .m4a | .ogg | .aac | .wma)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

# Returns 0 when nothing inside the item has been modified within the last
# $stabletime seconds, i.e. the copy into /input looks finished.
# Returns 1 when the item is still settling or cannot be inspected, in which
# case the caller must leave it completely alone and retry on a later pass.
is_stable() {
	local item="$1"
	local now newest age mtimes scanresult

	if [ "$stabletime" -le 0 ]; then
		return 0
	fi

	if [ ! -e "$item" ]; then
		log "  Skipping $item, it is no longer present"
		return 1
	fi

	if [ -d "$item" ]; then
		mtimes=$(find "$item" \( -type f -o -type d \) -exec stat -c '%Y' '{}' + 2>/dev/null)
		scanresult=$?
	else
		mtimes=$(stat -c '%Y' "$item" 2>/dev/null)
		scanresult=$?
	fi

	if [ "$scanresult" -ne 0 ]; then
		log "  Skipping $item, could not read modification times of everything in it"
		return 1
	fi

	newest=$(printf '%s\n' "$mtimes" | sort -n | tail -n 1)

	case "$newest" in
	'' | *[!0-9]*)
		log "  Skipping $item, could not determine when it was last modified"
		return 1
		;;
	esac

	now=$(date +%s)
	age=$((now - newest))

	if [ "$age" -lt 0 ]; then
		log "  Skipping $item, it was modified in the future, check the clock on the source"
		return 1
	fi

	if [ "$age" -lt "$stabletime" ]; then
		log "  Skipping $item, last modified ${age}s ago, waiting for ${stabletime}s of no activity"
		return 1
	fi

	return 0
}
