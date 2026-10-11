#!/bin/bash
# Draws the four landscapes (dawn, day, dusk, night) shown in the README's demo.
# Deterministic: the same ImageMagick produces the same files.
#
# Usage: demo/draw-backgrounds.sh [output-dir]   (default: demo/backgrounds)
set -euo pipefail
out=${1:-"$(dirname "$0")/backgrounds"}
mkdir -p "$out"
W=2560 H=1600

# A ridge line as a polygon: a sum of sines, filled down to the bottom edge.
ridge() { # base_y amplitude seed
  awk -v W=$W -v H=$H -v y0="$1" -v amp="$2" -v seed="$3" 'BEGIN {
    srand(seed); p1 = rand()*6.28; p2 = rand()*6.28; p3 = rand()*6.28
    printf "polygon 0,%d", H
    for (x = 0; x <= W; x += 16) {
      y = y0 - amp * (0.55*sin(x/W*6.28*1.3 + p1) + 0.3*sin(x/W*6.28*3.1 + p2) + 0.15*sin(x/W*6.28*7.7 + p3))
      printf " %d,%d", x, y
    }
    printf " %d,%d", W, H
  }'
}

scene() { # name sky_top sky_bottom sun_x sun_y sun_r sun_color glow_color ridge colours (far to near)...
  local name=$1 top=$2 bottom=$3 sx=$4 sy=$5 sr=$6 sun=$7 glow=$8; shift 8
  local args=() i=0
  for colour in "$@"; do
    args+=(-fill "$colour" -draw "$(ridge $(( 900 + i * 170 )) $(( 220 - i * 40 )) $(( ${name%%-*} * 101 + i * 13 )))")
    i=$((i + 1))
  done
  magick -size ${W}x${H} gradient:"$top"-"$bottom" \
    \( -size ${W}x${H} xc:none -fill "$glow" -draw "circle $sx,$sy $((sx + sr * 4)),$sy" -blur 0x120 \) -composite \
    -fill "$sun" -draw "circle $sx,$sy $((sx + sr)),$sy" \
    "${args[@]}" \
    -quality 92 "$out/$name.jpg"
}

scene 1-dawn  "#2b2d5c" "#f6a96b" 1700 760 70 "#ffe3b0" "#ffb27a90" "#7a4a6a" "#5a3557" "#3d2445" "#231530"
scene 2-day   "#4a90d9" "#cfe7f7" 820 380 80 "#fffbe8" "#ffffff70" "#7fa7c4" "#5d8aa8" "#3f6b86" "#284c63"
scene 3-dusk  "#3a1c4a" "#ff7a59" 1280 900 110 "#ffd27a" "#ff9a6a90" "#8a3f5c" "#652f4f" "#43223d" "#26142a"
scene 4-night "#05081a" "#1b2a4a" 1900 420 60 "#f4f1e0" "#c8d8ff40" "#26324f" "#1c2640" "#141b30" "#0b1020"

# Stars for the night sky, above the ridges.
stars=()
RANDOM=42
for _ in $(seq 260); do
  x=$(( RANDOM % W )) y=$(( RANDOM % 700 )) r=$(( RANDOM % 7 == 0 ? 2 : 1 ))
  stars+=(-draw "circle $x,$y $((x + r)),$y")
done
magick "$out/4-night.jpg" -fill '#ffffffcc' "${stars[@]}" -quality 92 "$out/4-night.jpg"
