# Base image with multi-platform support
FROM --platform=$TARGETPLATFORM python:3.9-slim

# Build arguments for multi-platform support
ARG TARGETPLATFORM
ARG TARGETARCH
ARG BUILDPLATFORM

# Set library architecture based on target architecture
RUN case ${TARGETARCH} in \
    amd64) echo "x86_64-linux-gnu" > /tmp/lib_arch ;; \
    arm64) echo "aarch64-linux-gnu" > /tmp/lib_arch ;; \
    arm) echo "arm-linux-gnueabihf" > /tmp/lib_arch ;; \
    *) echo "x86_64-linux-gnu" > /tmp/lib_arch ;; \
    esac

# Install system dependencies, build tools, and libraries
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    wget \
    tar \
    xz-utils \
    fonts-liberation \
    fontconfig \
    build-essential \
    yasm \
    cmake \
    meson \
    ninja-build \
    nasm \
    libssl-dev \
    libvpx-dev \
    libx264-dev \
    libx265-dev \
    libnuma-dev \
    libmp3lame-dev \
    libopus-dev \
    libvorbis-dev \
    libtheora-dev \
    libspeex-dev \
    libfreetype6-dev \
    libfontconfig1-dev \
    libgnutls28-dev \
    libaom-dev \
    libdav1d-dev \
    librav1e-dev \
    libsvtav1-dev \
    libzimg-dev \
    libwebp-dev \
    libunibreak-dev \
    libglib2.0-dev \
    git \
    pkg-config \
    autoconf \
    automake \
    libtool \
    libfribidi-dev \
    libharfbuzz-dev \
    libnss3 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libcups2 \
    libxcomposite1 \
    libxrandr2 \
    libxdamage1 \
    libgbm1 \
    libasound2 \
    libpangocairo-1.0-0 \
    libpangoft2-1.0-0 \
    libgtk-3-0 \
    && rm -rf /var/lib/apt/lists/*

# Install SRT from source
RUN git clone https://github.com/Haivision/srt.git && \
    cd srt && \
    mkdir build && cd build && \
    cmake .. && \
    make -j$(nproc) && \
    make install && \
    cd ../../.. && rm -rf srt && \
    ldconfig

# Install SVT-AV1 from source with ARM optimizations
RUN git clone https://gitlab.com/AOMediaCodec/SVT-AV1.git && \
    cd SVT-AV1 && \
    git checkout v0.9.0 && \
    cd Build && \
    cmake .. -DNATIVE=OFF && \
    make -j$(nproc) && \
    make install && \
    cd ../../.. && rm -rf SVT-AV1 && \
    ldconfig

# Install libvmaf from source
RUN git clone https://github.com/Netflix/vmaf.git && \
    cd vmaf/libvmaf && \
    meson build --buildtype release && \
    ninja -C build && \
    ninja -C build install && \
    cd ../../.. && rm -rf vmaf && \
    ldconfig

# Build and install fdk-aac
RUN git clone https://github.com/mstorsjo/fdk-aac && \
    cd fdk-aac && \
    autoreconf -fiv && \
    ./configure && \
    make -j$(nproc) && \
    make install && \
    cd .. && rm -rf fdk-aac && \
    ldconfig

# Build and install libunibreak from source (for latest version)
RUN git clone https://github.com/adah1972/libunibreak.git && \
    cd libunibreak && \
    ./autogen.sh && \
    ./configure && \
    make -j$(nproc) && \
    make install && \
    ldconfig && \
    cd .. && rm -rf libunibreak

# Build and install libass with libunibreak support
# Build and install libass with proper error handling
RUN git clone https://github.com/libass/libass.git && \
    cd libass && \
    autoreconf -i && \
    export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/lib/pkgconfig" && \
    export CFLAGS="-I/usr/local/include" && \
    export LDFLAGS="-L/usr/local/lib" && \
    ./configure --enable-libunibreak --enable-fontconfig --enable-harfbuzz || { \
        echo "=== CONFIGURATION FAILED ==="; \
        echo "Config log contents:"; \
        cat config.log; \
        echo "=== PKG-CONFIG DEBUG ==="; \
        pkg-config --list-all | grep -E "(unibreak|fribidi|harfbuzz|fontconfig)" || echo "No relevant packages found"; \
        exit 1; \
    } && \
    mkdir -p /app && cp config.log /app/config.log && \
    make -j$(nproc) || { \
        echo "=== BUILD FAILED ==="; \
        echo "Libass build failed"; \
        exit 1; \
    } && \
    make install && \
    ldconfig && \
    cd .. && rm -rf libass


# Build and install FFmpeg with architecture-aware paths
RUN git clone https://git.ffmpeg.org/ffmpeg.git ffmpeg && \
    cd ffmpeg && \
    git checkout n7.0.2 && \
    LIB_ARCH=$(cat /tmp/lib_arch) && \
    if [ "${TARGETARCH}" = "arm64" ] || [ "${TARGETARCH}" = "arm" ]; then \
        NEON_FLAG="--enable-neon"; \
    else \
        NEON_FLAG=""; \
    fi && \
    PKG_CONFIG_PATH="/usr/lib/${LIB_ARCH}/pkgconfig:/usr/local/lib/pkgconfig" \
    CFLAGS="-I/usr/include/freetype2" \
    LDFLAGS="-L/usr/lib/${LIB_ARCH}" \
    ./configure --prefix=/usr/local \
        --enable-gpl \
        --enable-pthreads \
        ${NEON_FLAG} \
        --enable-libaom \
        --enable-libdav1d \
        --enable-librav1e \
        --enable-libsvtav1 \
        --enable-libvmaf \
        --enable-libzimg \
        --enable-libx264 \
        --enable-libx265 \
        --enable-libvpx \
        --enable-libwebp \
        --enable-libmp3lame \
        --enable-libopus \
        --enable-libvorbis \
        --enable-libtheora \
        --enable-libspeex \
        --enable-libass \
        --enable-libfreetype \
        --enable-libharfbuzz \
        --enable-fontconfig \
        --enable-libsrt \
        --enable-filter=drawtext \
        --extra-cflags="-I/usr/include/freetype2 -I/usr/include/libpng16 -I/usr/include" \
        --extra-ldflags="-L/usr/lib/${LIB_ARCH} -lfreetype -lfontconfig" \
        --enable-gnutls \
    && make -j$(nproc) && \
    make install && \
    cd .. && rm -rf ffmpeg

# Add /usr/local/bin to PATH
ENV PATH="/usr/local/bin:${PATH}"

# Copy fonts into the custom fonts directory
COPY ./fonts /usr/share/fonts/custom

# Rebuild the font cache
RUN fc-cache -f -v

# Set work directory
WORKDIR /app

# Set environment variable for Whisper cache
ENV WHISPER_CACHE_DIR="/app/whisper_cache"

# Create the appuser and set up directories
RUN useradd -m appuser && \
    mkdir -p ${WHISPER_CACHE_DIR} && \
    chown -R appuser:appuser /app

# Copy the requirements file first to optimize caching
COPY requirements.txt .

# Install Python dependencies
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt && \
    pip install openai-whisper && \
    pip install playwright && \
    pip install jsonschema

# Switch to the appuser before downloading the model
USER appuser

# Download Whisper model
RUN python -c "import os; print(os.environ.get('WHISPER_CACHE_DIR')); import whisper; whisper.load_model('base')"

# Install Playwright Chromium browser as appuser
RUN playwright install chromium

# Copy the rest of the application code
COPY . .

# Expose the port the app runs on
EXPOSE 8080

# Set environment variables
ENV PYTHONUNBUFFERED=1

# Create the startup script
RUN echo '#!/bin/bash\n\
gunicorn --bind 0.0.0.0:8080 \
    --workers ${GUNICORN_WORKERS:-2} \
    --timeout ${GUNICORN_TIMEOUT:-300} \
    --worker-class sync \
    --keep-alive 80 \
    app:app' > /app/run_gunicorn.sh && \
    chmod +x /app/run_gunicorn.sh

# Run the application
CMD ["/app/run_gunicorn.sh"]
