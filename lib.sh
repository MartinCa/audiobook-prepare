#!/bin/bash
# Sourceable helper functions shared by process_mp3merge.sh and tests/lib.bats.
# Keep this file free of side effects (no cd/mkdir/loops) so it can be
# sourced safely in isolation.

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
		echo "  Skipping $item, it is no longer present"
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
		echo "  Skipping $item, could not read modification times of everything in it"
		return 1
	fi

	newest=$(printf '%s\n' "$mtimes" | sort -n | tail -n 1)

	case "$newest" in
	'' | *[!0-9]*)
		echo "  Skipping $item, could not determine when it was last modified"
		return 1
		;;
	esac

	now=$(date +%s)
	age=$((now - newest))

	if [ "$age" -lt 0 ]; then
		echo "  Skipping $item, it was modified in the future, check the clock on the source"
		return 1
	fi

	if [ "$age" -lt "$stabletime" ]; then
		echo "  Skipping $item, last modified ${age}s ago, waiting for ${stabletime}s of no activity"
		return 1
	fi

	return 0
}
