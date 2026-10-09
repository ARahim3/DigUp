#!/bin/bash
# Builds the testbed's synthetic media (no personal data): macOS sample pictures, synthetic UI screenshots,
# TTS speech clips, system sounds, and short videos cut into 6 s "moments".
#   ./make_media.sh <out_dir>
set -euo pipefail
M="${1:?usage: make_media.sh <out_dir>}"; HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$M/img" "$M/shots" "$M/audio" "$M/audio_trunc" "$M/video"

for d in Animals Flowers Fun Instruments Nature Sports; do
  for f in "/Library/User Pictures/$d"/*.heic; do
    sips -s format jpeg -Z 768 "$f" --out "$M/img/$d-$(basename "$f" .heic).jpg" >/dev/null
  done
done

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift "$HERE/make_screenshots.swift" "$M/shots"

# The default system voice renders silence from a script; Samantha works.
say_wav() { say -v Samantha -o "$M/audio/tmp.aiff" "$2"; ffmpeg -loglevel error -y -i "$M/audio/tmp.aiff" -ac 1 -ar 16000 "$M/audio/$1.wav"; rm "$M/audio/tmp.aiff"; }
say_wav speech_groceries "Don't forget to buy milk, eggs and bread on the way home tomorrow."
say_wav speech_revenue "Our quarterly revenue grew by twenty percent, driven by strong sales in Europe."
say_wav speech_flight_delay "Attention passengers. The flight to Tokyo has been delayed by two hours because of a storm."
say_wav speech_cake_recipe "In this recipe we will bake a chocolate cake. First, preheat the oven to one hundred eighty degrees, then mix the flour, sugar and cocoa powder in a large bowl. Add the eggs, the melted butter and the milk, and stir until the batter is smooth. Pour it into a greased pan and bake for thirty five minutes. While the cake is baking, prepare the frosting by whipping cream with a little sugar and vanilla. When the cake has cooled down completely, spread the frosting on top and decorate it with fresh strawberries and some grated chocolate."
for s in Purr Frog Submarine Glass; do ffmpeg -loglevel error -y -i "/System/Library/Sounds/$s.aiff" -ac 1 -ar 16000 "$M/audio/sfx_$s.wav"; done
ffmpeg -loglevel error -y -stream_loop 5 -i "$M/audio/speech_cake_recipe.wav" -t 60 "$M/audio/bench_60s.wav"

# Audio length-cap test clips
A="$M/audio"; T="$M/audio_trunc"
ffmpeg -loglevel error -y -i "$A/bench_60s.wav" -t 11 "$T/bench_first11s.wav"
ffmpeg -loglevel error -y -i "$A/bench_60s.wav" -t 30 "$T/bench_first30s.wav"
ffmpeg -loglevel error -y -ss 30 -i "$A/bench_60s.wav" -t 30 "$T/bench_last30s.wav"
ffmpeg -loglevel error -y -i "$A/speech_flight_delay.wav" -i "$A/speech_flight_delay.wav" -f lavfi -t 1 -i anullsrc=r=16000:cl=mono \
  -i "$A/speech_revenue.wav" -i "$A/speech_revenue.wav" -i "$A/speech_revenue.wav" -i "$A/speech_revenue.wav" \
  -filter_complex "[0][1][2][3][4][5][6]concat=n=7:v=0:a=1" -ac 1 -ar 16000 "$T/flight_then_revenue_29s.wav"

# 18 s video = penguin | zebra | parrot (6 s each), cut into 6 s moments; plus a 45 s bench video
I="$M/img"; V="$M/video"
ffmpeg -loglevel error -y -loop 1 -t 6 -i "$I/Animals-Penguin.jpg" -loop 1 -t 6 -i "$I/Animals-Zebra.jpg" -loop 1 -t 6 -i "$I/Animals-Parrot.jpg" \
  -filter_complex "[0:v]scale=768:768,setsar=1[a];[1:v]scale=768:768,setsar=1[b];[2:v]scale=768:768,setsar=1[c];[a][b][c]concat=n=3:v=1:a=0,format=yuv420p" \
  -r 24 "$V/penguin_zebra_parrot_18s.mp4"
for s in 0 6 12; do ffmpeg -loglevel error -y -ss $s -t 6 -i "$V/penguin_zebra_parrot_18s.mp4" -c:v libx264 -pix_fmt yuv420p "$V/seg_${s}s.mp4"; done
ffmpeg -loglevel error -y -stream_loop 2 -i "$V/penguin_zebra_parrot_18s.mp4" -t 45 -c copy "$V/bench_45s.mp4"
echo "media in $M"
