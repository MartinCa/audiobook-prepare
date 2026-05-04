# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Audiobook-prepare is a Docker-based automated audiobook processing system. It watches an input directory for audiobooks, converts multi-file MP3/MP4/M4A/OGG audiobooks into chapterized M4B format, and organizes output for downstream tagging tools.

## Build & Run Commands

```bash
# Build and run with Docker Compose
docker-compose up --build

# Build without cache (force full rebuild)
docker-compose build --no-cache

# For Podman users
podman compose up --build
podman compose build --no-cache
```

**Note:** A full build from scratch compiles fdk-aac and FFmpeg from source, which can take 10-20+ minutes depending on hardware. Subsequent builds with cache are much faster.

## Architecture

### Docker Multi-Stage Build

1. **Builder stage** (Alpine 3.23): Compiles fdk-aac, then FFmpeg with `--enable-nonfree --enable-libfdk-aac`. CFLAGS/CXXFLAGS/LDFLAGS are declared *after* the fdk-aac step so they only apply to FFmpeg's build.
2. **Runtime stage** (Alpine 3.23): Minimal image with only `shadow` and `bash`. The static `ffmpeg` and `ffprobe` binaries are copied from the builder.

### Processing Pipeline

- **Entry point**: `runscript.sh` - handles PUID/PGID user setup, then calls processing script
- **Core logic**: `process_mp3merge.sh` - main Bash script that:
  - Detects file types (.m4b, .mp3, .mp4, .m4a, .ogg, .aac, .wma)
  - Single M4B files: direct move to output
  - Single non-M4B files: convert with bitrate preservation (via `get_audio_bitrate` + FFmpeg)
  - Directories with multiple files: merge into single M4B with chapter markers derived from filenames (via `merge_to_m4b` using FFmpeg concat demuxer + ffmetadata)
  - Extracts companion ebooks (.mobi, .pdf, .epub, .azw, .azw3) to separate directory
  - Failed conversions isolated to `/failed` directory

### Volume Mounts

| Mount | Purpose |
|-------|---------|
| `/input` | Source audiobooks to process |
| `/output` | Converted M4B files |
| `/failed` | Failed conversions for debugging |
| `/ebookfiles` | Extracted companion ebooks |
| `/config` | Logs (processing.log) |

### Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| PUID/PGID | 1000 | Container user/group ID for file ownership |
| CPU_CORES | auto | Cores allocated to FFmpeg encoding (`-threads`) |
| MONITOR_DIR | 0 | 1=continuous monitoring, 0=single run |
| SLEEPTIME | 5m | Interval between processing runs |

## Key Tools Used

- **FFmpeg/FFprobe**: All audio conversion, merging, bitrate detection, and chapter generation. Built statically with libfdk-aac (high-quality AAC encoder).
