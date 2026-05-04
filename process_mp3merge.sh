#!/bin/bash

mp3mergedir="/input/"
untaggeddir="/output/"
faileddir="/failed/"
ebookfilesdir="/ebookfiles/"
logfile="/config/processing.log"
m4bext=".m4b"
cd "$mp3mergedir"

touch -a "$logfile"
mkdir -p "$mp3mergedir"
mkdir -p "$untaggeddir"
mkdir -p "$faileddir"
mkdir -p "$ebookfilesdir"

# CPU Cores used for ffmpeg encoding threads
if [ -z "$CPU_CORES" ]; then
	echo "Using all CPU cores as CPU_CORES ENV not set."
	CPUcores=$(nproc --all)
else
	echo "Using $CPU_CORES CPU cores as defined."
	CPUcores="$CPU_CORES"
fi

if [ "$MONITOR_DIR" != 1 ]; then
	echo "Only doing single run"
else
	echo "Continously running monitoring directory"
fi

# Run interval
if [ -z "$SLEEPTIME" ]; then
	echo "Using standard 5 min sleep time."
	sleeptime=5m
else
	echo "Using $SLEEPTIME sleep time."
	sleeptime="$SLEEPTIME"
fi

keep_running=1

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

MERGE_ERROR=""

# Merge all audio files in source_dir into a single M4B with chapter markers
# derived from filenames. Sets MERGE_ERROR and returns 1 on failure.
merge_to_m4b() {
	local source_dir="$1"
	local output_file="$2"
	local bitrate="$3"

	local tmpdir
	tmpdir=$(mktemp -d)
	local filelist="$tmpdir/files.txt"
	local metafile="$tmpdir/metadata.txt"

	printf ';FFMETADATA1\n' >"$metafile"

	local chapter_start=0
	local file_count=0

	while IFS= read -r -d $'\0' f; do
		local dur_ms
		dur_ms=$(ffprobe -v quiet \
			-show_entries format=duration \
			-of default=noprint_wrappers=1:nokey=1 \
			-i "$f" 2>/dev/null |
			awk '{printf "%d", int($1 * 1000 + 0.5)}')

		if [ -z "$dur_ms" ] || ! [ "$dur_ms" -gt 0 ] 2>/dev/null; then
			echo "  Warning: could not get duration for $f, skipping"
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
		MERGE_ERROR="No audio files found in $source_dir"
		printf '%s\n' "$MERGE_ERROR"
		return 1
	fi

	local tmplog
	tmplog=$(mktemp)
	ffmpeg -y -hide_banner \
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
		"$output_file" 2>&1 | tee "$tmplog"
	local result=${PIPESTATUS[0]}

	rm -rf "$tmpdir"

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
			cmdresult=1
			action="NONE"
			logerror=""
			echo "Processing $dir_item"

			full_source_path="$mp3mergedir$dir_item"
			destdir="$untaggeddir$dir_item/"

			if [ "$dir_item_is_mediafile" -eq 0 ]; then
				filename_excl_ext=${dir_item::-4}
				destdir="$untaggeddir$filename_excl_ext/"

				if [ "${dir_item: -4}" == ".m4b" ]; then
					# Separate m4b file in root, move straight to untagged for tagging
					action="MOVE"
					echo "  Moving single m4b file '$full_source_path' to '$destdir'"
					mkdir -p "$destdir"
					logerror=$(mv "$full_source_path" "$destdir" 2>&1)
					cmdresult=$?
				else
					# Separate non m4b file in root, convert to m4b
					m4bfilename="$filename_excl_ext$m4bext"

					action="MERGE"
					echo "  Converting single media file '$full_source_path' to '$destdir$m4bfilename'"

					if [ -f "$destdir$m4bfilename" ]; then
						logerror="Destination file '$destdir$m4bfilename' already exists"
						cmdresult=99
					else
						mkdir -p "$destdir"

						echo "  Sampling bitrate of $full_source_path"
						bitrate=$(get_audio_bitrate "$full_source_path")
						echo "  Detected bitrate of $bitrate"

						tmplog=$(mktemp)
						ffmpeg -y -hide_banner \
							-i "$full_source_path" \
							-c:a libfdk_aac \
							-b:a "$bitrate" \
							-vn \
							-threads "$CPUcores" \
							-f mp4 \
							"$destdir$m4bfilename" 2>&1 | tee "$tmplog"
						cmdresult=${PIPESTATUS[0]}

						if [ "$cmdresult" -ne 0 ]; then
							logerror=$(cat "$tmplog")
							rm -f "$destdir$m4bfilename"
							rmdir "$destdir" 2>/dev/null
						else
							echo "  Setting permissions"
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
					echo "  Copying single m4b file in '$full_source_path' to '$destdir'"
					mkdir -p "$destdir"
					logerror=$(cp "$full_source_path"/*.m4b "$destdir" 2>&1)
					cmdresult=$?
				else
					# We have either 0 or more than 1 m4b file so we have to merge the files.
					# Merged m4b file is output to untagged.
					action="MERGE"

					filename_excl_ext=$dir_item
					m4bfilename="$filename_excl_ext$m4bext"

					echo "  Merging $dir_item to $destdir$m4bfilename"

					if [ -f "$destdir$m4bfilename" ]; then
						logerror="Destination file '$destdir$m4bfilename' already exists"
						cmdresult=99
					else
						mkdir -p "$destdir"

						samplefile=$(find "$dir_item" -maxdepth 1 -mindepth 1 -type f \( -name '*.mp3' -o -name '*.m4b' -o -name '*.mp4' -o -name '*.m4a' -o -name '*.ogg' -o -name '*.aac' -o -name '*.wma' \) | head -n 1)

						if [ -z "$samplefile" ]; then
							bitrate=64000
						else
							echo "  Sampling bitrate of $samplefile"
							bitrate=$(get_audio_bitrate "$mp3mergedir$samplefile")
							echo "  Detected bitrate of $bitrate"
						fi

						if merge_to_m4b "$full_source_path" "$destdir$m4bfilename" "$bitrate"; then
							cmdresult=0
							echo "  Setting permissions"
							chmod -R a=,a+rwX "$destdir"
						else
							cmdresult=1
							logerror="$MERGE_ERROR"
							rm -f "$destdir$m4bfilename"
							rmdir "$destdir" 2>/dev/null
						fi
					fi
				fi

				# Move ebook files
				numberofebookfiles=$(find "$dir_item" -type f \( -name "*.mobi" -o -name "*.pdf" -o -name "*.epub" -o -name "*.azw" -o -name "*.azw3" -o -name "*.kfx" -o -name "*.fb2" -o -name "*.djvu" \) | wc -l)

				if [[ $numberofebookfiles -gt 0 ]]; then
					mkdir -p "$ebookfilesdir$dir_item"
					find "$dir_item" -type f \( -name "*.mobi" -o -name "*.pdf" -o -name "*.epub" -o -name "*.azw" -o -name "*.azw3" -o -name "*.kfx" -o -name "*.fb2" -o -name "*.djvu" \) -exec cp '{}' "$ebookfilesdir"'{}' \; -exec echo "  Moved ebook file to $ebookfilesdir"'{}' \;
					echo "$(date -I'seconds') MOVED Ebook files for $dir_item" >>"$logfile"
				fi

			fi

			if [ "$cmdresult" -eq 0 ]; then
				echo "  Processing succeeded"
				rm -rf "$full_source_path"
				echo "$(date -I'seconds') SUCCESS $action $dir_item" >>"$logfile"
			else
				echo "  ERROR: Processing failed: $logerror"
				cp -r "$full_source_path" "$faileddir" && rm -rf "$full_source_path"
				log_error=$(printf '%s' "$logerror" | tail -5 | tr '\n' '|')
				echo "$(date -I'seconds') FAILED $action $dir_item: $log_error" >>"$logfile"
			fi
		else
			echo "Ignored $dir_item"
		fi
		echo ""
	done

	if [ "$MONITOR_DIR" != 1 ]; then
		keep_running=0
	else
		echo "Done for now, sleeping for $sleeptime"
		sleep $sleeptime
	fi
done
