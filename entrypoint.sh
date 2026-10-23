#!/usr/bin/env bash
set -euo pipefail

export DISPLAY=:99

# Installed first: as PID 1 without a handler, bash would silently drop
# `docker stop` during startup and wait for the SIGKILL.
stop=0
ffmpeg_pids=()
# Each ffmpeg gets SIGINT once only: a second one aborts the final writes of
# the first and leaves an empty file.
signaled=0
stop_capture() {
  local p
  for p in "${ffmpeg_pids[@]:signaled}"; do kill -INT "$p" 2>/dev/null || true; done
  signaled=${#ffmpeg_pids[@]}
}
trap 'stop=1; stop_capture' INT TERM

wait_for() {
  local what=$1; shift
  for _ in $(seq 300); do
    "$@" >/dev/null 2>&1 && return 0
    (( stop )) && exit 0
    sleep 0.1
  done
  echo "timed out waiting for $what" >&2
  exit 1
}

# A restarted container keeps /tmp but restarts PIDs from 1, so stale pid and
# lock files point at live processes and the daemons refuse to start.
rm -f /tmp/pulse-*/pid /tmp/.X99-lock
rm -rf /tmp/chrome-profile
# Chrome's UI is English, so it offers to translate every other page with a
# bubble in the corner; --disable-features=Translate no longer stops that,
# the profile preference does.
mkdir -p /tmp/chrome-profile/Default
echo '{"translate":{"enabled":false}}' > /tmp/chrome-profile/Default/Preferences

pulseaudio --daemonize=yes --exit-idle-time=-1 --log-target=stderr
wait_for pulseaudio pactl info
pactl load-module module-null-sink sink_name=rec sink_properties=device.description=rec >/dev/null
pactl set-default-sink rec

# Without a window manager Chrome sizes a screen-filling window 1px short of
# the screen (black last row/column in the video), so the screen is 1px larger
# than the capture and Chrome's window lands exactly on the captured area.
Xvfb "$DISPLAY" -screen 0 "$((WIDTH + 1))x$((HEIGHT + 1))x24" -nolisten tcp &
wait_for Xvfb xdpyinfo

# --no-sandbox: Docker's default seccomp profile blocks the user namespaces
# Chrome's sandbox needs; the container is the isolation boundary instead.
google-chrome \
  --kiosk --window-position=0,0 --window-size="${WIDTH},${HEIGHT}" \
  --no-sandbox --no-first-run --no-default-browser-check \
  --disable-dev-shm-usage --disable-gpu \
  --autoplay-policy=no-user-gesture-required \
  --user-data-dir=/tmp/chrome-profile \
  --remote-debugging-port=9222 \
  "$( [[ -n "$COOKIES" ]] && echo about:blank || echo "$URL" )" >/tmp/chrome.log 2>&1 &
wait_for "Chrome DevTools" python3 -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:9222/json/version")'

# Backgrounded like the sleep below so a stop signal is handled right away.
# The limit covers browse.py's own worst case (page + ads + audio waits).
timeout 240 browse.py open "$URL" & wait $! || true
(( stop )) && exit 0

sleep "$WARMUP" & wait $! || true
(( stop )) && exit 0

# Video and audio are captured by separate ffmpeg processes. In one process
# ffmpeg holds the screen grab back whenever the PulseAudio input runs late,
# which it does at startup and while the page is silent, and the recording then
# repeats frames: 3-45 new frames/s measured for a 50 fps video. Both inputs
# stamp packets with the wall clock; -copyts keeps those stamps (Matroska
# stores them as they are) so the merge below can line the tracks up.
# Matroska also stays playable if ffmpeg is killed mid-recording.
# Frames keep x11grab's own timing, so the frame rate is only nominally
# constant. Forcing it is worse: -fps_mode cfr counts from 0 and would fill the
# decades before the first wall-clock stamp, and the fps filter, resampling
# 60 grabs/s onto a 60 fps grid, dropped and repeated frames on jitter in
# about one run in five (40-53 new frames/s instead of ~59). The encoder
# keeps x11grab's microsecond time base; the default 1/FPS one rounds two
# jittered grabs onto the same tick (non-monotonic PTS/DTS). No B-frames:
# Matroska stores whole milliseconds, and the DTS that B-frames shift off the
# PTS collided after that rounding. MP4 and NUT would keep finer stamps, but
# a killed MP4 loses the wall-clock start and a killed NUT can't be read.
# The extension test keeps a dot in a directory name (/out.d/rec) from
# being taken for one.
[[ ${OUT##*/} == *.* ]] && base=${OUT%.*} || base=$OUT
video=$base.video.mkv
audio=$base.audio.mka
limit=()
[[ -n "$DURATION" ]] && limit=(-t "$DURATION")
# A failed merge must not leave the previous run's recording to be copied out.
rm -f "$OUT"

# A short input queue: each entry is a raw frame (8 MB at 1080p), and a long
# one only hides an encoder that can't keep up until memory runs out.
ffmpeg -hide_banner -loglevel warning -y \
  -thread_queue_size 64 "${limit[@]}" -f x11grab -video_size "${WIDTH}x${HEIGHT}" -framerate "$FPS" -draw_mouse 0 -i "$DISPLAY" \
  -copyts -fps_mode passthrough -enc_time_base demux -c:v libx264 -preset veryfast -crf 23 -bf 0 -pix_fmt yuv420p \
  "$video" </dev/null &
ffmpeg_pids+=($!)
ffmpeg -hide_banner -loglevel warning -y \
  "${limit[@]}" -f pulse -i rec.monitor \
  -copyts -c:a aac -b:a 128k \
  "$audio" </dev/null &
ffmpeg_pids+=($!)
# A stop that arrived while the processes were starting found no pids to signal.
(( stop )) && stop_capture
# record.ps1 starts its timer on this line.
echo "recording started"
# Backgrounded: it keeps guarding the audio track for a few seconds, and the
# stop trap below must not wait for it.
# The delay lets x11grab deliver its first frames before the video moves.
(sleep 1; browse.py play) &

# Whichever capture ends first, the other is stopped too: a timed run ends
# both anyway, and a failed one must not leave the other recording until
# `docker stop`. A trapped signal interrupts `wait -n` with no pid, hence the
# loop. ffmpeg exits 255 after SIGINT even though it finalized its file.
declare -A exit_of
running=("${ffmpeg_pids[@]}")
while (( ${#running[@]} )); do
  pid= code=0
  wait -n -p pid "${running[@]}" || code=$?
  [[ -z "${pid:-}" ]] && continue  # an interrupted wait unsets it
  (( code == 255 )) && code=0
  exit_of[$pid]=$code
  left=()
  for p in "${running[@]}"; do [[ $p != "$pid" ]] && left+=("$p"); done
  running=("${left[@]}")
  (( ${#running[@]} )) && stop_capture
done
rc=${exit_of[${ffmpeg_pids[0]}]}
audio_rc=${exit_of[${ffmpeg_pids[1]}]}

start_of() { ffprobe -v error -show_entries format=start_time -of default=nw=1:nk=1 "$1" 2>/dev/null || true; }
merged=0
video_start=$(start_of "$video")
audio_start=$(start_of "$audio")
if [[ "$audio_start" =~ ^[0-9.]+$ && "$video_start" =~ ^[0-9.]+$ ]]; then
  # Whichever track started earlier is lined up with the other by the
  # difference of their wall-clock starts: an early audio head is cut, a late
  # one is delayed. -shortest ends the file with the shorter track, so a
  # stopped recording doesn't end in silence; it is left out when the audio
  # capture failed midway, which would otherwise cut the video down to it.
  shortest=(-shortest)
  if (( audio_rc )); then
    echo "audio capture failed (exit $audio_rc); the recording may have no sound towards the end" >&2
    shortest=()
  fi
  align=($(awk -v a="$audio_start" -v v="$video_start" \
    'BEGIN { d = a - v; if (d >= 0) printf "-itsoffset %.6f", d; else printf "-ss %.6f", -d }'))
  ffmpeg -hide_banner -loglevel error -y -i "$video" "${align[@]}" -i "$audio" \
    -map 0:v -map 1:a -c copy "${shortest[@]}" \
    -movflags +frag_keyframe+empty_moov+default_base_moof "$OUT.part.mp4" && merged=1
else
  echo "no usable audio track; saving the video alone" >&2
  ffmpeg -hide_banner -loglevel error -y -i "$video" -map 0:v -c copy \
    -movflags +frag_keyframe+empty_moov+default_base_moof "$OUT.part.mp4" && merged=1
fi
# Written to a temp name first, so a merge cut short by docker's stop timeout
# leaves the two capture files in place instead of a broken recording.
if (( merged )) && [[ -s "$OUT.part.mp4" ]]; then
  mv "$OUT.part.mp4" "$OUT" && rm -f "$video" "$audio"
else
  rm -f "$OUT.part.mp4"
  echo "merging $video and $audio failed; both are kept" >&2
  rc=1
fi
exit "$rc"
