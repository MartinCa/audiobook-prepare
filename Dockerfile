FROM docker.io/sandreas/tone:v0.2.4 as tone
FROM docker.io/library/alpine:3.16.9 as builder

ARG MP4V2_URL="https://github.com/enzo1982/mp4v2/archive/refs/tags/v2.1.3.zip"

ARG FDK_AAC_VERSION=2.0.3
ARG FDK_AAC_URL="https://github.com/mstorsjo/fdk-aac/archive/v$FDK_AAC_VERSION.tar.gz"

# Reference: https://github.com/sandreas/dockerhub-builds

RUN echo "---- INSTALL BUILD DEPENDENCIES ----" \
    && apk add --no-cache --update --upgrade --virtual=build-dependencies \
    autoconf \
    libtool \
    automake \
    boost-dev \
    build-base \
    gcc \
    git \
    tar \
    wget

RUN echo "---- COMPILE MP4V2 ----" \
    && cd /tmp/ \
    && wget "${MP4V2_URL}" -O mp4v2.zip \
    && unzip mp4v2.zip \
    && cd mp4v2* \
    && autoreconf -fiv \
    && ./configure && \
    make -j$(nproc) && \
    make install && make distclean

RUN echo "---- PREPARE FDKAAC-DEPENDENCIES ----" \
    && cd /tmp/ \
    && wget -O fdk-aac.tar.gz "$FDK_AAC_URL" \
    && tar xfz fdk-aac.tar.gz \
    && cd fdk-aac-* && ./autogen.sh && ./configure --enable-static --disable-shared && make -j$(nproc) install

RUN echo "---- COMPILE FDKAAC ENCODER (executable binary for usage of --audio-profile) ----" \
    && cd /tmp/ \
    && wget https://github.com/nu774/fdkaac/archive/v1.0.6.tar.gz \
    && tar xzf v1.0.6.tar.gz \
    && cd fdkaac-1.0.6 \
    && autoreconf -i && ./configure --enable-static --disable-shared && make -j$(nproc) && make install && rm -rf /tmp/*

## START FFMPEG BUILD
# Reference: https://github.com/wader/static-ffmpeg

# -O3 makes sure we compile with optimization. setting CFLAGS/CXXFLAGS seems to override
# default automake cflags.
# -static-libgcc is needed to make gcc not include gcc_s as "as-needed" shared library which
# cmake will include as a implicit library.
# other options to get hardened build (same as ffmpeg hardened)
ARG CFLAGS="-O3 -s -static-libgcc -fno-strict-overflow -fstack-protector-all -fPIC"
ARG CXXFLAGS="-O3 -s -static-libgcc -fno-strict-overflow -fstack-protector-all -fPIC"
ARG LDFLAGS="-Wl,-z,relro,-z,now"

# retry dns and some http codes that might be transient errors
ARG WGET_OPTS="--retry-on-host-error --retry-on-http-error=429,500,502,503"

RUN echo "---- INSTALL FFMPEG BUILD DEPENDENCIES ----" && \
    apk add --no-cache \
    coreutils \
    rust cargo \
    openssl-dev openssl-libs-static \
    ca-certificates \
    bash \
    diffutils \
    cmake meson ninja \
    yasm nasm \
    texinfo \
    jq \
    zlib-dev zlib-static \
    bzip2-dev bzip2-static \
    libxml2-dev \
    expat-dev expat-static \
    fontconfig-dev fontconfig-static \
    freetype freetype-dev freetype-static \
    graphite2-static \
    glib-static \
    tiff tiff-dev \
    libjpeg-turbo libjpeg-turbo-dev \
    libpng-dev libpng-static \
    giflib giflib-dev \
    harfbuzz-dev harfbuzz-static \
    fribidi-dev fribidi-static \
    brotli-dev brotli-static \
    soxr-dev soxr-static \
    tcl \
    numactl-dev \
    cunit cunit-dev \
    fftw-dev \
    libsamplerate-dev \
    xxd

# Removed because fdk-aac is build above
# bump: fdk-aac /FDK_AAC_VERSION=([\d.]+)/ https://github.com/mstorsjo/fdk-aac.git|*
# bump: fdk-aac after ./hashupdate Dockerfile FDK_AAC $LATEST
# bump: fdk-aac link "ChangeLog" https://github.com/mstorsjo/fdk-aac/blob/master/ChangeLog
# bump: fdk-aac link "Source diff $CURRENT..$LATEST" https://github.com/mstorsjo/fdk-aac/compare/v$CURRENT..v$LATEST
# RUN \
#   wget $WGET_OPTS -O fdk-aac.tar.gz "$FDK_AAC_URL" && \
#   echo "$FDK_AAC_SHA256  fdk-aac.tar.gz" | sha256sum --status -c - && \
#   tar xf fdk-aac.tar.gz && \
#   cd fdk-aac-* && ./autogen.sh && ./configure --disable-shared --enable-static && \
#   make -j$(nproc) install

# bump: mp3lame /MP3LAME_VERSION=([\d.]+)/ svn:http://svn.code.sf.net/p/lame/svn|/^RELEASE__(.*)$/|/_/./|*
# bump: mp3lame after ./hashupdate Dockerfile MP3LAME $LATEST
# bump: mp3lame link "ChangeLog" http://svn.code.sf.net/p/lame/svn/trunk/lame/ChangeLog
ARG MP3LAME_VERSION=3.100
ARG MP3LAME_URL="https://sourceforge.net/projects/lame/files/lame/$MP3LAME_VERSION/lame-$MP3LAME_VERSION.tar.gz/download"
ARG MP3LAME_SHA256=ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e
RUN echo "---- MP3LAME ----" && \
    wget $WGET_OPTS -O lame.tar.gz "$MP3LAME_URL" && \
    echo "$MP3LAME_SHA256  lame.tar.gz" | sha256sum --status -c - && \
    tar xf lame.tar.gz && \
    cd lame-* && ./configure --disable-shared --enable-static --enable-nasm --disable-gtktest --disable-cpml --disable-frontend && \
    make -j$(nproc) install

# bump: opencoreamr /OPENCOREAMR_VERSION=([\d.]+)/ fetch:https://sourceforge.net/projects/opencore-amr/files/opencore-amr/|/opencore-amr-([\d.]+).tar.gz/
# bump: opencoreamr after ./hashupdate Dockerfile OPENCOREAMR $LATEST
# bump: opencoreamr link "ChangeLog" https://sourceforge.net/p/opencore-amr/code/ci/master/tree/ChangeLog
ARG OPENCOREAMR_VERSION=0.1.6
ARG OPENCOREAMR_URL="https://sourceforge.net/projects/opencore-amr/files/opencore-amr/opencore-amr-$OPENCOREAMR_VERSION.tar.gz"
ARG OPENCOREAMR_SHA256=483eb4061088e2b34b358e47540b5d495a96cd468e361050fae615b1809dc4a1
RUN echo "---- opencore ----" && \
    wget $WGET_OPTS -O opencoreamr.tar.gz "$OPENCOREAMR_URL" && \
    echo "$OPENCOREAMR_SHA256  opencoreamr.tar.gz" | sha256sum --status -c - && \
    tar xf opencoreamr.tar.gz && \
    cd opencore-amr-* && ./configure --enable-static --disable-shared && \
    make -j$(nproc) install

# bump: openjpeg /OPENJPEG_VERSION=([\d.]+)/ https://github.com/uclouvain/openjpeg.git|*
# bump: openjpeg after ./hashupdate Dockerfile OPENJPEG $LATEST
# bump: openjpeg link "CHANGELOG" https://github.com/uclouvain/openjpeg/blob/master/CHANGELOG.md
ARG OPENJPEG_VERSION=2.5.3
ARG OPENJPEG_URL="https://github.com/uclouvain/openjpeg/archive/v$OPENJPEG_VERSION.tar.gz"
ARG OPENJPEG_SHA256=368fe0468228e767433c9ebdea82ad9d801a3ad1e4234421f352c8b06e7aa707
RUN echo "---- openjpeg ----" && \
    wget $WGET_OPTS -O openjpeg.tar.gz "$OPENJPEG_URL" && \
    echo "$OPENJPEG_SHA256  openjpeg.tar.gz" | sha256sum --status -c - && \
    tar xf openjpeg.tar.gz && \
    cd openjpeg-* && mkdir build && cd build && \
    cmake \
    -G"Unix Makefiles" \
    -DCMAKE_VERBOSE_MAKEFILE=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_PKGCONFIG_FILES=ON \
    -DBUILD_CODEC=OFF \
    -DWITH_ASTYLE=OFF \
    -DBUILD_TESTING=OFF \
    .. && \
    make -j$(nproc) install

# bump: opus /OPUS_VERSION=([\d.]+)/ https://github.com/xiph/opus.git|^1
# bump: opus after ./hashupdate Dockerfile OPUS $LATEST
# bump: opus link "Release notes" https://github.com/xiph/opus/releases/tag/v$LATEST
# bump: opus link "Source diff $CURRENT..$LATEST" https://github.com/xiph/opus/compare/v$CURRENT..v$LATEST
ARG OPUS_VERSION=1.3.1
ARG OPUS_URL="https://archive.mozilla.org/pub/opus/opus-$OPUS_VERSION.tar.gz"
ARG OPUS_SHA256=65b58e1e25b2a114157014736a3d9dfeaad8d41be1c8179866f144a2fb44ff9d
RUN echo "---- opus ----" && \
    wget $WGET_OPTS -O opus.tar.gz "$OPUS_URL" && \
    echo "$OPUS_SHA256  opus.tar.gz" | sha256sum --status -c - && \
    tar xf opus.tar.gz && \
    cd opus-* && ./configure --disable-shared --enable-static --disable-extra-programs --disable-doc && \
    make -j$(nproc) install

# bump: LIBSHINE /LIBSHINE_VERSION=([\d.]+)/ https://github.com/toots/shine.git|*
# bump: LIBSHINE after ./hashupdate Dockerfile LIBSHINE $LATEST
# bump: LIBSHINE link "CHANGELOG" https://github.com/toots/shine/blob/master/ChangeLog
# bump: LIBSHINE link "Source diff $CURRENT..$LATEST" https://github.com/toots/shine/compare/$CURRENT..$LATEST
ARG LIBSHINE_VERSION=3.1.1
ARG LIBSHINE_URL="https://github.com/toots/shine/releases/download/$LIBSHINE_VERSION/shine-$LIBSHINE_VERSION.tar.gz"
ARG LIBSHINE_SHA256=58e61e70128cf73f88635db495bfc17f0dde3ce9c9ac070d505a0cd75b93d384
RUN echo "---- libshine ----" && \
    wget $WGET_OPTS -O libshine.tar.gz "$LIBSHINE_URL" && \
    echo "$LIBSHINE_SHA256  libshine.tar.gz" | sha256sum --status -c - && \
    tar xf libshine.tar.gz && cd shine* && \
    ./configure --with-pic --enable-static --disable-shared --disable-fast-install && \
    make -j$(nproc) install

# bump: speex /SPEEX_VERSION=([\d.]+)/ https://github.com/xiph/speex.git|*
# bump: speex after ./hashupdate Dockerfile SPEEX $LATEST
# bump: speex link "ChangeLog" https://github.com/xiph/speex//blob/master/ChangeLog
# bump: speex link "Source diff $CURRENT..$LATEST" https://github.com/xiph/speex/compare/$CURRENT..$LATEST
ARG SPEEX_VERSION=1.2.1
ARG SPEEX_URL="https://github.com/xiph/speex/archive/Speex-$SPEEX_VERSION.tar.gz"
ARG SPEEX_SHA256=beaf2642e81a822eaade4d9ebf92e1678f301abfc74a29159c4e721ee70fdce0
RUN echo "---- speex ----" && \
    wget $WGET_OPTS -O speex.tar.gz "$SPEEX_URL" && \
    echo "$SPEEX_SHA256  speex.tar.gz" | sha256sum --status -c - && \
    tar xf speex.tar.gz && \
    cd speex-Speex-* && ./autogen.sh && ./configure --disable-shared --enable-static && \
    make -j$(nproc) install

# has to be before theora
# bump: ogg /OGG_VERSION=([\d.]+)/ https://github.com/xiph/ogg.git|*
# bump: ogg after ./hashupdate Dockerfile OGG $LATEST
# bump: ogg link "CHANGES" https://github.com/xiph/ogg/blob/master/CHANGES
# bump: ogg link "Source diff $CURRENT..$LATEST" https://github.com/xiph/ogg/compare/v$CURRENT..v$LATEST
ARG OGG_VERSION=1.3.5
ARG OGG_URL="https://downloads.xiph.org/releases/ogg/libogg-$OGG_VERSION.tar.gz"
ARG OGG_SHA256=0eb4b4b9420a0f51db142ba3f9c64b333f826532dc0f48c6410ae51f4799b664
RUN echo "---- ogg ----" && \
    wget $WGET_OPTS -O libogg.tar.gz "$OGG_URL" && \
    echo "$OGG_SHA256  libogg.tar.gz" | sha256sum --status -c - && \
    tar xf libogg.tar.gz && \
    cd libogg-* && ./configure --disable-shared --enable-static && \
    make -j$(nproc) install

# bump: theora /THEORA_VERSION=([\d.]+)/ https://github.com/xiph/theora.git|*
# bump: theora after ./hashupdate Dockerfile THEORA $LATEST
# bump: theora link "Release notes" https://github.com/xiph/theora/releases/tag/v$LATEST
# bump: theora link "Source diff $CURRENT..$LATEST" https://github.com/xiph/theora/compare/v$CURRENT..v$LATEST
ARG THEORA_VERSION=1.1.1
ARG THEORA_URL="https://downloads.xiph.org/releases/theora/libtheora-$THEORA_VERSION.tar.bz2"
ARG THEORA_SHA256=b6ae1ee2fa3d42ac489287d3ec34c5885730b1296f0801ae577a35193d3affbc
RUN echo "---- theora ----" && \
    wget $WGET_OPTS -O libtheora.tar.bz2 "$THEORA_URL" && \
    echo "$THEORA_SHA256  libtheora.tar.bz2" | sha256sum --status -c - && \
    tar xf libtheora.tar.bz2 && \
    # --build=$(arch)-unknown-linux-gnu helps with guessing the correct build. For some reason,
    # build script can't guess the build type in arm64 (hardware and emulated) environment.
    cd libtheora-* && ./configure --build=$(arch)-unknown-linux-gnu --disable-examples --disable-oggtest --disable-shared --enable-static && \
    make -j$(nproc) install


# bump: twolame /TWOLAME_VERSION=([\d.]+)/ https://github.com/njh/twolame.git|*
# bump: twolame after ./hashupdate Dockerfile TWOLAME $LATEST
# bump: twolame link "Source diff $CURRENT..$LATEST" https://github.com/njh/twolame/compare/v$CURRENT..v$LATEST
ARG TWOLAME_VERSION=0.4.0
ARG TWOLAME_URL="https://github.com/njh/twolame/releases/download/$TWOLAME_VERSION/twolame-$TWOLAME_VERSION.tar.gz"
ARG TWOLAME_SHA256=cc35424f6019a88c6f52570b63e1baf50f62963a3eac52a03a800bb070d7c87d
RUN echo "---- twolame ----" && \
    wget $WGET_OPTS -O twolame.tar.gz "$TWOLAME_URL" && \
    echo "$TWOLAME_SHA256  twolame.tar.gz" | sha256sum --status -c - && \
    tar xf twolame.tar.gz && \
    cd twolame-* && ./configure --disable-shared --enable-static --disable-sndfile --with-pic && \
    make -j$(nproc) install

# bump: vorbis /VORBIS_VERSION=([\d.]+)/ https://github.com/xiph/vorbis.git|*
# bump: vorbis after ./hashupdate Dockerfile VORBIS $LATEST
# bump: vorbis link "CHANGES" https://github.com/xiph/vorbis/blob/master/CHANGES
# bump: vorbis link "Source diff $CURRENT..$LATEST" https://github.com/xiph/vorbis/compare/v$CURRENT..v$LATEST
ARG VORBIS_VERSION=1.3.7
ARG VORBIS_URL="https://downloads.xiph.org/releases/vorbis/libvorbis-$VORBIS_VERSION.tar.gz"
ARG VORBIS_SHA256=0e982409a9c3fc82ee06e08205b1355e5c6aa4c36bca58146ef399621b0ce5ab
RUN echo "---- vorbis ----" && \
    wget $WGET_OPTS -O libvorbis.tar.gz "$VORBIS_URL" && \
    echo "$VORBIS_SHA256  libvorbis.tar.gz" | sha256sum --status -c - && \
    tar xf libvorbis.tar.gz && \
    cd libvorbis-* && ./configure --disable-shared --enable-static --disable-oggtest && \
    make -j$(nproc) install


# bump: libvpx /VPX_VERSION=([\d.]+)/ https://github.com/webmproject/libvpx.git|*
# bump: libvpx after ./hashupdate Dockerfile VPX $LATEST
# bump: libvpx link "CHANGELOG" https://github.com/webmproject/libvpx/blob/master/CHANGELOG
# bump: libvpx link "Source diff $CURRENT..$LATEST" https://github.com/webmproject/libvpx/compare/v$CURRENT..v$LATEST
#ARG VPX_VERSION=1.12.0
#ARG VPX_URL="https://github.com/webmproject/libvpx/archive/v$VPX_VERSION.tar.gz"
#ARG VPX_SHA256=f1acc15d0fd0cb431f4bf6eac32d5e932e40ea1186fe78e074254d6d003957bb
#RUN \
#  wget $WGET_OPTS -O libvpx.tar.gz "$VPX_URL" && \
#  echo "$VPX_SHA256  libvpx.tar.gz" | sha256sum --status -c - && \
#  tar xf libvpx.tar.gz && \
#  cd libvpx-* && ./configure --enable-static --enable-vp9-highbitdepth --disable-shared --disable-unit-tests --disable-examples && \
#  make -j$(nproc) install


# bump: libwebp /LIBWEBP_VERSION=([\d.]+)/ https://github.com/webmproject/libwebp.git|*
# bump: libwebp after ./hashupdate Dockerfile LIBWEBP $LATEST
# bump: libwebp link "Release notes" https://github.com/webmproject/libwebp/releases/tag/v$LATEST
# bump: libwebp link "Source diff $CURRENT..$LATEST" https://github.com/webmproject/libwebp/compare/v$CURRENT..v$LATEST
ARG LIBWEBP_VERSION=1.5.0
ARG LIBWEBP_URL="https://github.com/webmproject/libwebp/archive/v$LIBWEBP_VERSION.tar.gz"
ARG LIBWEBP_SHA256=668c9aba45565e24c27e17f7aaf7060a399f7f31dba6c97a044e1feacb930f37
RUN echo "---- libwebp ----" && \
    wget $WGET_OPTS -O libwebp.tar.gz "$LIBWEBP_URL" && \
    echo "$LIBWEBP_SHA256  libwebp.tar.gz" | sha256sum --status -c - && \
    tar xf libwebp.tar.gz && \
    cd libwebp-* && ./autogen.sh && ./configure --disable-shared --enable-static --with-pic --enable-libwebpmux --disable-libwebpextras --disable-libwebpdemux --disable-sdl --disable-gl --disable-png --disable-jpeg --disable-tiff --disable-gif && \
    make -j$(nproc) install

# bump: ffmpeg /FFMPEG_VERSION=([\d.]+)/ https://github.com/FFmpeg/FFmpeg.git|^5
# bump: ffmpeg after ./hashupdate Dockerfile FFMPEG $LATEST
# bump: ffmpeg link "Changelog" https://github.com/FFmpeg/FFmpeg/blob/n$LATEST/Changelog
# bump: ffmpeg link "Source diff $CURRENT..$LATEST" https://github.com/FFmpeg/FFmpeg/compare/n$CURRENT..n$LATEST
ARG FFMPEG_VERSION=6.1.2
ARG FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.bz2"
ARG FFMPEG_SHA256=62fe9fd098cb537d4b61731b11049e1ac179f38c870a41b8e9d556af944edb45
# sed changes --toolchain=hardened -pie to -static-pie
# extra ldflags stack-size=2097152 is to increase default stack size from 128KB (musl default) to something
# more similar to glibc (2MB). This fixing segfault with libaom-av1 and libsvtav1 as they seems to pass
# large things on the stack.
RUN echo "---- FFMPEG BUILD ----" && \
    wget $WGET_OPTS -O ffmpeg.tar.bz2 "$FFMPEG_URL" && \
    echo "$FFMPEG_SHA256  ffmpeg.tar.bz2" | sha256sum --status -c - && \
    tar xf ffmpeg.tar.bz2 && \
    cd ffmpeg-* && \
    sed -i 's/add_ldexeflags -fPIE -pie/add_ldexeflags -fPIE -static-pie/' configure && \
    ./configure \
    --pkg-config-flags="--static" \
    --extra-cflags="-fopenmp" \
    --extra-ldflags="-fopenmp -Wl,-z,stack-size=2097152" \
    --toolchain=hardened \
    --disable-debug \
    --disable-shared \
    --disable-ffplay \
    --enable-static \
    --enable-gpl \
    --enable-version3 \
    --enable-nonfree \
    --enable-fontconfig \
    --enable-gray \
    --enable-iconv \
    --enable-libfdk-aac \
    --enable-libfreetype \
    --enable-libfribidi \
    --enable-libmp3lame \
    --enable-libopencore-amrnb \
    --enable-libopencore-amrwb \
    --enable-libopenjpeg \
    --enable-libopus \
    --enable-libshine \
    --enable-libsoxr \
    --enable-libspeex \
    --enable-libtheora \
    --enable-libtwolame \
    --enable-libvorbis \
    --enable-libwebp \
    --enable-libxml2 \
    --enable-openssl \
    || (cat ffbuild/config.log ; false) \
    && make -j$(nproc) install

RUN echo "---- output versions ----" && \
    EXPAT_VERSION=$(pkg-config --modversion expat) \
    FFTW_VERSION=$(pkg-config --modversion fftw3) \
    FONTCONFIG_VERSION=$(pkg-config --modversion fontconfig)  \
    FREETYPE_VERSION=$(pkg-config --modversion freetype2)  \
    FRIBIDI_VERSION=$(pkg-config --modversion fribidi)  \
    LIBSAMPLERATE_VERSION=$(pkg-config --modversion samplerate) \
    LIBXML2_VERSION=$(pkg-config --modversion libxml-2.0) \
    OPENSSL_VERSION=$(pkg-config --modversion openssl) \
    SOXR_VERSION=$(pkg-config --modversion soxr) \
    jq -n \
    '{ \
    expat: env.EXPAT_VERSION, \
    "libfdk-aac": env.FDK_AAC_VERSION, \
    ffmpeg: env.FFMPEG_VERSION, \
    fftw: env.FFTW_VERSION, \
    fontconfig: env.FONTCONFIG_VERSION, \
    libfreetype: env.FREETYPE_VERSION, \
    libfribidi: env.FRIBIDI_VERSION, \
    libmp3lame: env.MP3LAME_VERSION, \
    libogg: env.LIBOGG_VERSION, \
    libopencoreamr: env.OPENCOREAMR_VERSION, \
    libopenjpeg: env.OPENJPEG_VERSION, \
    libopus: env.OPUS_VERSION, \
    libsamplerate: env.LIBSAMPLERATE_VERSION, \
    libshine: env.LIBSHINE_VERSION, \
    libsoxr: env.SOXR_VERSION, \
    libspeex: env.SPEEX_VERSION, \
    libtheora: env.THEORA_VERSION, \
    libtwolame: env.TWOLAME_VERSION, \
    libvorbis: env.VORBIS_VERSION, \
    libwebp: env.LIBWEBP_VERSION, \
    libxml2: env.LIBXML2_VERSION, \
    openssl: env.OPENSSL_VERSION, \
    }' > /versions.json
## END FFMPEG BUILD

# Removed because this build image is just intermediate
# RUN echo "---- REMOVE BUILD DEPENDENCIES (to keep image small) ----" \
#     && apk del --purge build-dependencies && rm -rf /tmp/*

## Actual image
FROM alpine:3.16.2

RUN echo "---- INSTALL RUNTIME PACKAGES ----" && \
    apk add --no-cache --update --upgrade \
    # user manipulation
    shadow \
    # mp4v2: required libraries
    libstdc++ \
    # m4b-tool: php cli, required extensions and php settings
    php8-cli \
    php8-dom \
    php8-json \
    php8-xml \
    php8-mbstring \
    php8-phar \
    php8-tokenizer \
    php8-xmlwriter \
    php8-openssl \
    && echo "date.timezone = UTC" >> /etc/php8/php.ini \
    && ln -s /usr/bin/php8 /bin/php


# mp4v2
COPY --from=builder /usr/local/bin/mp4* /usr/local/bin/
COPY --from=builder /usr/local/lib/libmp4v2* /usr/local/lib/

# fdkaac
COPY --from=builder /usr/local/bin/fdkaac /usr/local/bin/

# ffmpeg
COPY --from=builder /usr/local/bin/ffmpeg /usr/local/bin/
COPY --from=builder /usr/local/bin/ffprobe /usr/local/bin/

# tone
COPY --from=tone /usr/local/bin/tone /usr/local/bin/

# m4b-tool
ARG M4B_TOOL_DOWNLOAD_LINK="https://github.com/sandreas/m4b-tool/releases/latest/download/m4b-tool.phar"
RUN echo "---- INSTALL M4B-TOOL ----" \
    && if [ ! -f /tmp/m4b-tool.phar ]; then \
    wget "${M4B_TOOL_DOWNLOAD_LINK}" -O /tmp/m4b-tool.phar && \
    if [ ! -f /tmp/m4b-tool.phar ]; then \
    tar xzf /tmp/m4b-tool.tar.gz -C /tmp/ && rm /tmp/m4b-tool.tar.gz ;\
    fi \
    fi \
    && mv /tmp/m4b-tool.phar /usr/local/bin/m4b-tool \
    && M4B_TOOL_PRE_RELEASE_LINK=$(wget -q -O - https://github.com/sandreas/m4b-tool/releases/tag/latest | grep -o 'M4B_TOOL_DOWNLOAD_LINK=[^ ]*' | head -1 | cut -d '=' -f 2) \
    && wget "${M4B_TOOL_PRE_RELEASE_LINK}" -O /tmp/m4b-tool.tar.gz \
    && tar xzf /tmp/m4b-tool.tar.gz -C /tmp/ && rm /tmp/m4b-tool.tar.gz \
    && mv /tmp/m4b-tool.phar /usr/local/bin/m4b-tool-pre \
    && chmod +x /usr/local/bin/m4b-tool /usr/local/bin/m4b-tool-pre

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
