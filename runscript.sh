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

su -c "/app/process_mp3merge.sh" -m appuser
