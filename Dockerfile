FROM docker.io/library/alpine:3.24 AS builder

RUN echo "---- INSTALL BUILD DEPENDENCIES ----" && \
    apk add --no-cache \
    autoconf \
    automake \
    libtool \
    build-base \
    ca-certificates \
    curl \
    pkgconf \
    nasm \
    yasm \
    bzip2 \
    openssl-dev openssl-libs-static \
    zlib-dev zlib-static

# bump: fdk-aac /FDK_AAC_VERSION=([\d.]+)/ https://github.com/mstorsjo/fdk-aac.git|*
# bump: fdk-aac after ./hashupdate Dockerfile FDK_AAC $LATEST
# bump: fdk-aac link "ChangeLog" https://github.com/mstorsjo/fdk-aac/blob/master/ChangeLog
# bump: fdk-aac link "Source diff $CURRENT..$LATEST" https://github.com/mstorsjo/fdk-aac/compare/v$CURRENT..v$LATEST
ARG FDK_AAC_VERSION=2.0.3
ARG FDK_AAC_URL="https://github.com/mstorsjo/fdk-aac/archive/v$FDK_AAC_VERSION.tar.gz"
ARG FDK_AAC_SHA256=e25671cd96b10bad896aa42ab91a695a9e573395262baed4e4a2ff178d6a3a78
RUN echo "---- COMPILE FDK-AAC ----" && \
    curl -fSL --retry 3 --retry-delay 2 -o /tmp/fdk-aac.tar.gz "$FDK_AAC_URL" && \
    echo "$FDK_AAC_SHA256  /tmp/fdk-aac.tar.gz" | sha256sum -c - && \
    tar xf /tmp/fdk-aac.tar.gz -C /tmp && \
    cd /tmp/fdk-aac-${FDK_AAC_VERSION} && ./autogen.sh && \
    ./configure --enable-static --disable-shared && \
    make -j$(nproc) install && \
    rm -rf /tmp/fdk-aac*

# CFLAGS/CXXFLAGS/LDFLAGS are declared here so they apply only to the FFmpeg build
# and do not interfere with fdk-aac's configure/make above.
# -O3 makes sure we compile with optimization. setting CFLAGS/CXXFLAGS seems to override
# default automake cflags.
# -static-libgcc is needed to make gcc not include gcc_s as "as-needed" shared library which
# cmake will include as a implicit library.
# other options to get hardened build (same as ffmpeg hardened)
ARG CFLAGS="-O3 -s -static-libgcc -fno-strict-overflow -fstack-protector-all -fPIC -std=gnu17"
ARG CXXFLAGS="-O3 -s -static-libgcc -fno-strict-overflow -fstack-protector-all -fPIC -std=gnu++17"
ARG LDFLAGS="-Wl,-z,relro,-z,now"

# bump: ffmpeg /FFMPEG_VERSION=([\d.]+)/ https://github.com/FFmpeg/FFmpeg.git|^7
# bump: ffmpeg after ./hashupdate Dockerfile FFMPEG $LATEST
# bump: ffmpeg link "Changelog" https://github.com/FFmpeg/FFmpeg/blob/n$LATEST/Changelog
# bump: ffmpeg link "Source diff $CURRENT..$LATEST" https://github.com/FFmpeg/FFmpeg/compare/n$CURRENT..n$LATEST
ARG FFMPEG_VERSION=7.1.4
ARG FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.bz2"
ARG FFMPEG_SHA256=de02003e8a7f7b08179ddf4a1fdc2599570ca02725fec9a1e465374fd4e514aa
# sed changes --toolchain=hardened -pie to -static-pie
RUN echo "---- COMPILE FFMPEG ----" && \
    curl -fSL --retry 3 --retry-delay 2 -o /tmp/ffmpeg.tar.bz2 "$FFMPEG_URL" && \
    echo "$FFMPEG_SHA256  /tmp/ffmpeg.tar.bz2" | sha256sum -c - && \
    tar xf /tmp/ffmpeg.tar.bz2 -C /tmp && \
    cd /tmp/ffmpeg-${FFMPEG_VERSION} && \
    sed -i 's/add_ldexeflags -fPIE -pie/add_ldexeflags -fPIE -static-pie/' configure && \
    ./configure \
    --pkg-config-flags="--static" \
    --toolchain=hardened \
    --disable-debug \
    --disable-shared \
    --disable-ffplay \
    --disable-doc \
    --enable-static \
    --enable-gpl \
    --enable-version3 \
    --enable-nonfree \
    --enable-libfdk-aac \
    --enable-openssl \
    || (cat ffbuild/config.log ; false) \
    && make -j$(nproc) install \
    && rm -rf /tmp/ffmpeg*

## Actual image
FROM docker.io/library/alpine:3.24

RUN echo "---- INSTALL RUNTIME PACKAGES ----" && \
    apk add --no-cache --update --upgrade \
    # user manipulation
    shadow \
    # bash for process script
    bash

# ffmpeg
COPY --from=builder /usr/local/bin/ffmpeg /usr/local/bin/
COPY --from=builder /usr/local/bin/ffprobe /usr/local/bin/

# Volumes and environment
VOLUME /input
VOLUME /output
VOLUME /failed
VOLUME /ebookfiles
VOLUME /config

ENV PUID=""
ENV PGID=""
ENV CPU_CORES=""
ENV MONITOR_DIR=1
ENV SLEEPTIME=""

#Import scripts
WORKDIR /app
COPY runscript.sh /app/
COPY process_mp3merge.sh /app/
RUN addgroup appgroup -g 911
RUN adduser -D -u 911 -h /app -G appgroup appuser
RUN chown appuser:appgroup /app/*.sh
RUN chmod +x /app/*.sh

ENTRYPOINT [ "./runscript.sh" ]
