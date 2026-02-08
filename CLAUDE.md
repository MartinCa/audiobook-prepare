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

## Architecture

### Docker Multi-Stage Build

1. **Builder stage** (Alpine 3.19): Compiles FFmpeg 6.1.2 with extensive codec support (libfdk-aac, opus, vorbis, mp3lame, etc.), mp4v2, and fdkaac
2. **Runtime stage** (Alpine 3.19): Minimal image with PHP 8.2, compiled binaries, and m4b-tool

### Processing Pipeline

- **Entry point**: `runscript.sh` - handles PUID/PGID user setup, then calls processing script
- **Core logic**: `process_mp3merge.sh` - main Bash script that:
  - Detects file types (.m4b, .mp3, .mp4, .m4a, .ogg, .aac, .wma)
  - Single M4B files: direct move to output
  - Single non-M4B files: convert with bitrate preservation
  - Directories with multiple files: merge into single M4B with chapters from filenames
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
| CPU_CORES | auto | Cores allocated to m4b-tool |
| MONITOR_DIR | 0 | 1=continuous monitoring, 0=single run |
| SLEEPTIME | 5m | Interval between processing runs |

## Key Tools Used

- **m4b-tool**: PHP-based audiobook conversion (downloads latest release at build time)
- **FFmpeg/FFprobe**: Audio conversion and bitrate detection
- **Tone**: Audio analysis utility
- **fdkaac**: High-quality AAC encoder
