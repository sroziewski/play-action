FROM debian:trixie-slim

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg \
      xvfb x11-utils \
      pulseaudio pulseaudio-utils \
      ffmpeg \
      python3 python3-websocket \
      fonts-liberation fonts-noto-color-emoji \
 && curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
      | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg \
 && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
      > /etc/apt/sources.list.d/google-chrome.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends google-chrome-stable \
 && apt-get purge -y --auto-remove curl gnupg \
 && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --uid 1000 rec \
 && mkdir /out && chown rec:rec /out

COPY --chmod=755 entrypoint.sh browse.py /usr/local/bin/

USER rec
WORKDIR /home/rec

ENV URL=https://example.com \
    WIDTH=1920 \
    HEIGHT=1080 \
    FPS=60 \
    DURATION= \
    WARMUP=3 \
    YT_FULLSCREEN=1 \
    COOKIES= \
    COOKIE_BANNER=reject \
    OUT=/out/recording.mp4 \
    AUDIO_ONLY=0 \
    AUDIO_BITRATE=256 \
    AUDIO_FORMAT=m4a

VOLUME /out
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
