#!/bin/sh
umask 0000

PUID=${PUID:-911}
PGID=${PGID:-911}

groupmod -o -g "$PGID" appgroup
usermod -o -u "$PUID" appuser

echo "
User uid: $(id -u appuser)
User gid: $(id -g appuser)
"

# exec (not fork via `su`) so process_mp3merge.sh replaces this shell as PID 1
# and receives termination signals directly instead of them being swallowed.
exec su-exec appuser:appgroup /app/process_mp3merge.sh
