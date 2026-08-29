#!/bin/bash

shopt -s nullglob

source "$(dirname "$0")/lib.sh"

mp3mergedir="/input/"
untaggeddir="/output/"
faileddir="/failed/"
ebookfilesdir="/ebookfiles/"
logfile="/config/processing.log"
m4bext=".m4b"
ebook_find_args=( -name "*.mobi" -o -name "*.pdf" -o -name "*.epub" -o -name "*.azw" -o -name "*.azw3" -o -name "*.kfx" -o -name "*.fb2" -o -name "*.djvu" )

cd "$mp3mergedir"

touch -a "$logfile"
mkdir -p "$mp3mergedir"
mkdir -p "$untaggeddir"
mkdir -p "$faileddir"
mkdir -p "$ebookfilesdir"

# CPU Cores used for ffmpeg encoding threads
if [ -z "$CPU_CORES" ]; then
	log "Using all CPU cores as CPU_CORES ENV not set."
	CPUcores=$(nproc --all)
else
	log "Using $CPU_CORES CPU cores as defined."
	CPUcores="$CPU_CORES"
fi

if [ "$MONITOR_DIR" != 1 ]; then
	log "Only doing single run"
else
	log "Continously running monitoring directory"
fi

# Run interval
if [ -z "$SLEEPTIME" ]; then
	log "Using standard 5 min sleep time."
	sleeptime=5m
else
	log "Using $SLEEPTIME sleep time."
	sleeptime="$SLEEPTIME"
fi

# Time an item must be untouched before it is considered fully copied
if [ -z "$STABLE_TIME" ]; then
	log "Using standard 2 min stability window."
	stabletime=120
else
	stabletime=$(duration_to_seconds "$STABLE_TIME")
	if [ -z "$stabletime" ]; then
		log "Could not understand STABLE_TIME '$STABLE_TIME', using standard 2 min stability window."
		stabletime=120
	elif [ "$stabletime" -eq 0 ]; then
		log "Stability window disabled as STABLE_TIME is 0, items are processed as soon as they are seen."
	else
		log "Using $stabletime second stability window."
	fi
fi

# Full decode of every finished m4b before it is published
if [ -z "$VERIFY_OUTPUT" ] || [ "$VERIFY_OUTPUT" = 1 ]; then
	verifyoutput=1
	log "Verifying finished m4b files by decoding them in full."
else
	verifyoutput=0
	log "Not verifying finished m4b files as VERIFY_OUTPUT is '$VERIFY_OUTPUT'."
fi

if [ "$stabletime" -gt 0 ] && ! stat -c '%Y' "$logfile" >/dev/null 2>&1; then
	log "ERROR: 'stat -c %Y' is not supported in this image, cannot verify that files have finished copying."
	log "ERROR: Nothing will be processed. Set STABLE_TIME=0 to disable the check (unsafe) or fix the image."
	echo "$(date -I'seconds') ERROR stat unsupported, stability check cannot run" >>"$logfile"
fi

keep_running=1

# PID/paths of the ffmpeg work currently in flight, so a termination signal
# can stop it and clean up instead of leaving a partial/corrupt file behind
# for a future run to trip over.
CURRENT_FFMPEG_PID=""
CURRENT_PARTIAL_OUTPUT=""
CURRENT_TMPDIR=""

handle_termination() {
	log "Received termination signal, shutting down"

	if [ -n "$CURRENT_FFMPEG_PID" ] && kill -0 "$CURRENT_FFMPEG_PID" 2>/dev/null; then
		log "  Stopping in-progress ffmpeg (pid $CURRENT_FFMPEG_PID)"
		kill -TERM "$CURRENT_FFMPEG_PID" 2>/dev/null
		wait "$CURRENT_FFMPEG_PID" 2>/dev/null
	fi

	if [ -n "$CURRENT_PARTIAL_OUTPUT" ] && [ -f "$CURRENT_PARTIAL_OUTPUT" ]; then
		log "  Removing partial output '$CURRENT_PARTIAL_OUTPUT'"
		rm -f "$CURRENT_PARTIAL_OUTPUT"
	fi

	if [ -n "$CURRENT_TMPDIR" ] && [ -d "$CURRENT_TMPDIR" ]; then
		log "  Removing temp directory '$CURRENT_TMPDIR'"
		rm -rf "$CURRENT_TMPDIR"
	fi

	echo "$(date -I'seconds') INTERRUPTED processing stopped by termination signal" >>"$logfile"
	log "Exiting"
	exit 143
}

trap handle_termination TERM INT

get_audio_bitrate() {
	local file="$1"
	local bitrate

	# Try stream-level bitrate first (more accurate for VBR formats)
	bitrate=$(ffprobe -hide_banner -loglevel quiet \
		-select_streams a:0 \
		-show_entries stream=bit_rate \
		-of default=noprint_wrappers=1:nokey=1 \
		-i "$file" 2>/dev/null)

	# Fall back to container bitrate
	if [ -z "$bitrate" ] || [ "$bitrate" = "N/A" ]; then
		bitrate=$(ffprobe -hide_banner -loglevel quiet \
			-show_entries format=bit_rate \
			-of default=noprint_wrappers=1:nokey=1 \
			-i "$file" 2>/dev/null)
	fi

	# Default to 64 kbps if still unavailable
	if [ -z "$bitrate" ] || [ "$bitrate" = "N/A" ]; then
		bitrate=64000
	fi

	echo "$bitrate"
}

# Duration of a media file in whole milliseconds, empty if it cannot be read.
probe_duration_ms() {
	ffprobe -v quiet \
		-show_entries format=duration \
		-of default=noprint_wrappers=1:nokey=1 \
		-i "$1" 2>/dev/null |
		awk '{printf "%d", int($1 * 1000 + 0.5)}'
}

VERIFY_ERROR=""

# Decode a finished m4b from end to end to confirm it is intact before it is
# published, whether it was merged, converted or just passed through. Three
# things have to hold, cheapest first so a hopeless file fails in milliseconds:
#
#   1. It has an audio stream and a duration at all.
#   2. Decoding every sample produces no errors. ffmpeg exits 0 on plenty of
#      decode errors, so any output at -v error counts as a failure too.
#   3. As much audio comes out as the container claims to hold. A truncated
#      mp4 decodes perfectly cleanly, it just stops early, which is exactly
#      what a copy onto a full disk or a half-written mux looks like.
#
# Sets VERIFY_ERROR and returns 1 on failure.
verify_m4b() {
	local file="$1"

	VERIFY_ERROR=""

	if [ "$verifyoutput" -ne 1 ]; then
		return 0
	fi

	log "  Verifying '$file'"

	if [ ! -s "$file" ]; then
		VERIFY_ERROR="'$file' is missing or empty"
		return 1
	fi

	local codec_type
	codec_type=$(ffprobe -hide_banner -loglevel quiet \
		-select_streams a:0 \
		-show_entries stream=codec_type \
		-of default=noprint_wrappers=1:nokey=1 \
		-i "$file" 2>/dev/null)

	if [ "$codec_type" != "audio" ]; then
		VERIFY_ERROR="'$file' has no audio stream"
		return 1
	fi

	local declared_ms
	declared_ms=$(probe_duration_ms "$file")

	if [ -z "$declared_ms" ] || ! [ "$declared_ms" -gt 0 ] 2>/dev/null; then
		VERIFY_ERROR="'$file' reports no duration"
		return 1
	fi

	local tmpdir
	tmpdir=$(mktemp -d)
	CURRENT_TMPDIR="$tmpdir"
	local progressfile="$tmpdir/progress"
	local tmplog="$tmpdir/ffmpeg.log"

	# -progress writes to a file rather than a pipe so $! stays ffmpeg's own
	# pid for the termination trap, and -nostats keeps stderr free of progress
	# chatter so that its emptiness is a meaningful signal.
	#
	# CURRENT_PARTIAL_OUTPUT is deliberately left unset here: unlike everywhere
	# else in this script the file is a finished deliverable, and on the
	# pass-through path it is the only copy left, so a termination signal must
	# not delete it.
	ffmpeg -nostdin -hide_banner -v error -xerror \
		-threads "$CPUcores" \
		-nostats -progress "$progressfile" \
		-i "$file" \
		-map 0:a \
		-f null - >/dev/null 2>"$tmplog" &
	CURRENT_FFMPEG_PID=$!
	wait "$CURRENT_FFMPEG_PID"
	local result=$?
	CURRENT_FFMPEG_PID=""

	if [ "$result" -ne 0 ] || [ -s "$tmplog" ]; then
		VERIFY_ERROR="could not decode '$file': $(tail -5 "$tmplog")"
		rm -rf "$tmpdir"
		CURRENT_TMPDIR=""
		return 1
	fi

	local decoded_ms
	decoded_ms=$(last_progress_ms "$progressfile")

	rm -rf "$tmpdir"
	CURRENT_TMPDIR=""

	if [ -z "$decoded_ms" ]; then
		VERIFY_ERROR="could not determine how much of '$file' decoded"
		return 1
	fi

	if ! duration_is_plausible "$declared_ms" "$decoded_ms"; then
		VERIFY_ERROR="'$file' is incomplete, decoded ${decoded_ms}ms of the ${declared_ms}ms it declares"
		return 1
	fi

	log "  Verified $(format_duration "$decoded_ms") of audio"
	return 0
}

# Losslessly remux an m4b in place to normalize its chunk layout.
#
# Files that only pass through this tool untouched (a lone source .m4b that
# is just moved/copied to /output) can already carry a QuickTime chapter
# track whose sample data is stored non-contiguously (interleaved with the
# audio track's own data) by whatever originally produced them. That layout
# is invisible to playback and most tag readers, but tools that rewrite
# tags in place with a read-modify-write MP4 muxer (e.g. the ATL library)
# refuse to touch such a chapter track and silently drop all chapter data,
# so the "fix" turns into a no-op save. A `-c copy` remux rebuilds the
# chunk-offset tables and makes the chapter samples contiguous again.
#
# Best-effort: on failure the original file is left untouched and a warning
# is logged, since this is a safety net on top of already-working output,
# not something that should fail the whole job.
remux_m4b() {
	local file="$1"
	local tmpfile="$file.remux.tmp"
	local tmplog
	tmplog=$(mktemp)

	CURRENT_PARTIAL_OUTPUT="$tmpfile"
	ffmpeg -y -hide_banner -loglevel error \
		-i "$file" \
		-c copy \
		-map_metadata 0 \
		-f mp4 \
		"$tmpfile" > >(tee "$tmplog") 2>&1 &
	CURRENT_FFMPEG_PID=$!
	wait "$CURRENT_FFMPEG_PID"
	local result=$?
	CURRENT_FFMPEG_PID=""
	CURRENT_PARTIAL_OUTPUT=""

	if [ $result -ne 0 ] || [ ! -s "$tmpfile" ]; then
		log "  Warning: could not normalize chapter layout of '$file', keeping original: $(cat "$tmplog" | tail -3)"
		rm -f "$tmpfile" "$tmplog"
		return 1
	fi

	mv "$tmpfile" "$file"
	rm -f "$tmplog"
	return 0
}

MERGE_ERROR=""

# Merge all audio files in source_dir into a single M4B with chapter markers
# derived from filenames. Sets MERGE_ERROR and returns 1 on failure.
merge_to_m4b() {
	local source_dir="$1"
	local output_file="$2"
	local bitrate="$3"

	local tmpdir
	tmpdir=$(mktemp -d)
	CURRENT_TMPDIR="$tmpdir"
	local filelist="$tmpdir/files.txt"
	local metafile="$tmpdir/metadata.txt"

	printf ';FFMETADATA1\n' >"$metafile"

	local chapter_start=0
	local file_count=0

	while IFS= read -r -d $'\0' f; do
		local dur_ms
		dur_ms=$(probe_duration_ms "$f")

		if [ -z "$dur_ms" ] || ! [ "$dur_ms" -gt 0 ] 2>/dev/null; then
			log "  Warning: could not get duration for $f, skipping"
			continue
		fi

		local chapter_end=$((chapter_start + dur_ms))
		local title
		title=$(basename "${f%.*}")

		printf '[CHAPTER]\nTIMEBASE=1/1000\nSTART=%d\nEND=%d\ntitle=%s\n\n' \
			"$chapter_start" "$chapter_end" "$title" >>"$metafile"

		printf "file '%s'\n" "${f//\'/\'\\\'\'}" >>"$filelist"

		chapter_start=$chapter_end
		file_count=$((file_count + 1))
	done < <(find "$source_dir" -maxdepth 1 -mindepth 1 -type f \
		\( -name '*.mp3' -o -name '*.m4b' -o -name '*.mp4' -o -name '*.m4a' \
		-o -name '*.ogg' -o -name '*.aac' -o -name '*.wma' \) \
		-print0 | sort -z)

	if [ "$file_count" -eq 0 ]; then
		rm -rf "$tmpdir"
		CURRENT_TMPDIR=""
		MERGE_ERROR="No audio files found in $source_dir"
		log "$MERGE_ERROR"
		return 1
	fi

	local tmplog
	tmplog=$(mktemp)
	CURRENT_PARTIAL_OUTPUT="$output_file"
	ffmpeg -y -hide_banner -loglevel error -stats -stats_period 30 \
		-f concat -safe 0 -i "$filelist" \
		-i "$metafile" \
		-map 0:a \
		-map_metadata 1 \
		-map_chapters 1 \
		-c:a libfdk_aac \
		-b:a "$bitrate" \
		-vn \
		-threads "$CPUcores" \
		-f mp4 \
		"$output_file" > >(tee "$tmplog") 2>&1 &
	CURRENT_FFMPEG_PID=$!
	wait "$CURRENT_FFMPEG_PID"
	local result=$?
	CURRENT_FFMPEG_PID=""
	CURRENT_PARTIAL_OUTPUT=""

	rm -rf "$tmpdir"
	CURRENT_TMPDIR=""

	if [ $result -ne 0 ]; then
		MERGE_ERROR=$(cat "$tmplog")
		rm -f "$tmplog"
		return 1
	fi
	rm -f "$tmplog"
	return 0
}

while [ "$keep_running" -eq 1 ]; do
	dir_content=*

	for dir_item in $dir_content; do
		is_media_file "$dir_item"
		dir_item_is_mediafile=$?

		if [ -d "$dir_item" ] || [ "$dir_item_is_mediafile" -eq 0 ]; then
			if ! is_stable "$dir_item"; then
				echo ""
				continue
			fi

			cmdresult=1
			action="NONE"
			logerror=""
			log "Processing $dir_item"

			full_source_path="$mp3mergedir$dir_item"
			destdir="$untaggeddir$dir_item/"

			# What gets moved to /failed if this item fails. The pass-through
			# path points it at /output instead, because by the time that path
			# can fail the source is no longer in /input to quarantine.
			quarantine_source="$full_source_path"

			if [ "$dir_item_is_mediafile" -eq 0 ]; then
				filename_excl_ext=${dir_item::-4}
				destdir="$untaggeddir$filename_excl_ext/"

				if [ "${dir_item: -4}" == ".m4b" ]; then
					# Separate m4b file in root, move straight to untagged for tagging
					action="MOVE"
					log "  Moving single m4b file '$full_source_path' to '$destdir'"
					mkdir -p "$destdir"
					logerror=$(mv "$full_source_path" "$destdir" 2>&1)
					cmdresult=$?

					if [ "$cmdresult" -eq 0 ]; then
						log "  Normalizing chapter layout of '$destdir$dir_item'"
						remux_m4b "$destdir$dir_item"

						if ! verify_m4b "$destdir$dir_item"; then
							cmdresult=1
							logerror="Verification failed: $VERIFY_ERROR"
							quarantine_source="${destdir%/}"
						fi
					fi
				else
					# Separate non m4b file in root, convert to m4b
					m4bfilename="$filename_excl_ext$m4bext"

					action="MERGE"
					log "  Converting single media file '$full_source_path' to '$destdir$m4bfilename'"

					if [ -f "$destdir$m4bfilename" ]; then
						logerror="Destination file '$destdir$m4bfilename' already exists"
						cmdresult=99
					else
						mkdir -p "$destdir"

						log "  Sampling bitrate of $full_source_path"
						bitrate=$(get_audio_bitrate "$full_source_path")
						log "  Detected bitrate of $bitrate"

						tmplog=$(mktemp)
						CURRENT_PARTIAL_OUTPUT="$destdir$m4bfilename"
						ffmpeg -y -hide_banner -loglevel error -stats -stats_period 30 \
							-i "$full_source_path" \
							-c:a libfdk_aac \
							-b:a "$bitrate" \
							-vn \
							-threads "$CPUcores" \
							-f mp4 \
							"$destdir$m4bfilename" > >(tee "$tmplog") 2>&1 &
						CURRENT_FFMPEG_PID=$!
						wait "$CURRENT_FFMPEG_PID"
						cmdresult=$?
						CURRENT_FFMPEG_PID=""
						CURRENT_PARTIAL_OUTPUT=""

						if [ "$cmdresult" -eq 0 ]; then
							if ! verify_m4b "$destdir$m4bfilename"; then
								cmdresult=1
								logerror="Verification failed: $VERIFY_ERROR"
							fi
						else
							logerror=$(cat "$tmplog")
						fi

						if [ "$cmdresult" -ne 0 ]; then
							rm -f "$destdir$m4bfilename"
							rmdir "$destdir" 2>/dev/null
						else
							log "  Setting permissions"
							chmod -R a=,a+rwX "$destdir"
						fi
						rm -f "$tmplog"
					fi
				fi
			else
				# Directory
				numberofm4bfiles=$(find "$dir_item" -type f -name '*.m4b' | wc -l)

				if [[ $numberofm4bfiles -eq 1 ]]; then
					# Only 1 m4b file so we copy dir straight to untagged for tagging
					action="COPY"
					log "  Copying single m4b file in '$full_source_path' to '$destdir'"
					mkdir -p "$destdir"
					logerror=$(cp "$full_source_path"/*.m4b "$destdir" 2>&1)
					cmdresult=$?

					if [ "$cmdresult" -eq 0 ]; then
						for copied_m4b in "$destdir"*.m4b; do
							log "  Normalizing chapter layout of '$copied_m4b'"
							remux_m4b "$copied_m4b"

							if ! verify_m4b "$copied_m4b"; then
								cmdresult=1
								logerror="Verification failed: $VERIFY_ERROR"
								rm -rf "$destdir"
								break
							fi
						done
					fi
				else
					# We have either 0 or more than 1 m4b file so we have to merge the files.
					# Merged m4b file is output to untagged.
					action="MERGE"

					filename_excl_ext=$dir_item
					m4bfilename="$filename_excl_ext$m4bext"

					log "  Merging $dir_item to $destdir$m4bfilename"

					if [ -f "$destdir$m4bfilename" ]; then
						logerror="Destination file '$destdir$m4bfilename' already exists"
						cmdresult=99
					else
						mkdir -p "$destdir"

						samplefile=$(find "$dir_item" -maxdepth 1 -mindepth 1 -type f \( -name '*.mp3' -o -name '*.m4b' -o -name '*.mp4' -o -name '*.m4a' -o -name '*.ogg' -o -name '*.aac' -o -name '*.wma' \) | head -n 1)

						if [ -z "$samplefile" ]; then
							bitrate=64000
						else
							log "  Sampling bitrate of $samplefile"
							bitrate=$(get_audio_bitrate "$mp3mergedir$samplefile")
							log "  Detected bitrate of $bitrate"
						fi

						if merge_to_m4b "$full_source_path" "$destdir$m4bfilename" "$bitrate"; then
							cmdresult=0

							if ! verify_m4b "$destdir$m4bfilename"; then
								cmdresult=1
								logerror="Verification failed: $VERIFY_ERROR"
							fi
						else
							cmdresult=1
							logerror="$MERGE_ERROR"
						fi

						if [ "$cmdresult" -eq 0 ]; then
							log "  Setting permissions"
							chmod -R a=,a+rwX "$destdir"
						else
							rm -f "$destdir$m4bfilename"
							rmdir "$destdir" 2>/dev/null
						fi
					fi
				fi

				# Move ebook files
				numberofebookfiles=$(find "$dir_item" -type f \( "${ebook_find_args[@]}" \) | wc -l)

				if [[ $numberofebookfiles -gt 0 ]]; then
					mkdir -p "$ebookfilesdir$dir_item"
					find "$dir_item" -type f \( "${ebook_find_args[@]}" \) -exec cp '{}' "$ebookfilesdir"'{}' \; -exec echo "  Moved ebook file to $ebookfilesdir"'{}' \;
					echo "$(date -I'seconds') MOVED Ebook files for $dir_item" >>"$logfile"
				fi

			fi

			if [ "$cmdresult" -eq 0 ]; then
				log "  Processing succeeded"
				rm -rf "$full_source_path"
				echo "$(date -I'seconds') SUCCESS $action $dir_item" >>"$logfile"
			else
				log "  ERROR: Processing failed: $logerror"
				cp -r "$quarantine_source" "$faileddir" && rm -rf "$quarantine_source"
				log_error=$(printf '%s' "$logerror" | tail -5 | tr '\n' '|')
				echo "$(date -I'seconds') FAILED $action $dir_item: $log_error" >>"$logfile"
			fi
		else
			log "Ignored $dir_item"
		fi
		echo ""
	done

	if [ "$MONITOR_DIR" != 1 ]; then
		keep_running=0
	else
		log "Done for now, sleeping for $sleeptime"
		sleep $sleeptime
	fi
done
