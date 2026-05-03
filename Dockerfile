FROM docker.io/library/alpine:3.23 AS builder

# retry dns and some http codes that might be transient errors
ARG WGET_OPTS="--retry-on-host-error --retry-on-http-error=429,500,502,503"

RUN echo "---- INSTALL BUILD DEPENDENCIES ----" && \
    apk add --no-cache \
    autoconf \
    automake \
    libtool \
    build-base \
    ca-certificates \
    pkgconf \
    wget \
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
RUN echo "---- FDK-AAC: download ----" && \
    cd /tmp && \
    wget $WGET_OPTS -O fdk-aac.tar.gz "$FDK_AAC_URL" && \
    echo "$FDK_AAC_SHA256  fdk-aac.tar.gz" | sha256sum --status -c -

RUN echo "---- FDK-AAC: extract ----" && \
    tar xf /tmp/fdk-aac.tar.gz -C /tmp

RUN echo "---- FDK-AAC: autogen ----" && \
    cd /tmp/fdk-aac-${FDK_AAC_VERSION} && ./autogen.sh

RUN echo "---- FDK-AAC: configure ----" && \
    cd /tmp/fdk-aac-${FDK_AAC_VERSION} && \
    ./configure --enable-static --disable-shared

RUN echo "---- FDK-AAC: make install ----" && \
    cd /tmp/fdk-aac-${FDK_AAC_VERSION} && \
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
ARG FFMPEG_VERSION=7.1.3
ARG FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.bz2"
ARG FFMPEG_SHA256=e7df715136a1231598dadb70fe6abd5cd66abc1ac2f470a02c567b2600c5292b
# sed changes --toolchain=hardened -pie to -static-pie
RUN echo "---- FFMPEG BUILD ----" && \
    wget $WGET_OPTS -O ffmpeg.tar.bz2 "$FFMPEG_URL" && \
    echo "$FFMPEG_SHA256  ffmpeg.tar.bz2" | sha256sum --status -c - && \
    tar xf ffmpeg.tar.bz2 && \
    cd ffmpeg-* && \
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
    && make -j$(nproc) install

## Actual image
FROM docker.io/library/alpine:3.23

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
