#!/bin/bash
# Makes screen-size copies of backgrounds, so a workspace switch decodes a few
# megapixels instead of the full file (theme backgrounds run to 8192x5461).
#
# Usage: screen-copies.sh <cache-dir> <WxH[,WxH...]> <image>...
#
# Prints "<WxH>|<image><TAB><copy>" for every image that has a copy, as soon as
# that copy is ready. An image no larger than the screen gets no copy: it is
# cheap to decode as it is. Copies are named by content, so a theme that
# reuses a file name (every stock theme has an omarchy.png) gets its own copy.
# Opaque images become JPEG; images with an alpha channel become PNG. Copies
# unused for 30 days are deleted.

set -uo pipefail

dir=$1
IFS=, read -ra sizes <<<"$2"
shift 2
mkdir -p "$dir" || exit 1

for src in "$@"; do
  [[ -f $src ]] || continue
  # %[channels] is the colour space and the channel count, alpha included:
  # "srgb 3.0" is opaque, "srgb 4.0" has an alpha channel.
  read -r width height colorspace count _ < <(magick identify -ping -format '%w %h %[channels]\n' "$src[0]" 2>/dev/null | head -n1) || continue
  [[ $width =~ ^[0-9]+$ && $height =~ ^[0-9]+$ && ${count%%.*} =~ ^[0-9]+$ ]] || continue
  case $colorspace in
    *gray*) colour_channels=1 ;;
    cmyk*) colour_channels=4 ;;
    *) colour_channels=3 ;;
  esac
  if (( ${count%%.*} > colour_channels )); then
    format=png
  else
    format=jpg
  fi
  key=$(sha1sum <"$src" | cut -c1-16)

  for size in "${sizes[@]}"; do
    [[ $size =~ ^([0-9]+)x([0-9]+)$ ]] || continue
    screen_width=${BASH_REMATCH[1]}
    screen_height=${BASH_REMATCH[2]}
    # Only a file that has to shrink to cover the screen is worth a copy.
    (( width > screen_width && height > screen_height )) || continue

    copy="$dir/$key-$size.$format"
    if [[ -s $copy ]]; then
      touch -c "$copy"
    else
      partial="$copy.partial.$$"
      if ! nice -n 10 magick "$src[0]" -resize "${size}^" -strip -quality 95 "$format:$partial"; then
        rm -f "$partial"
        continue
      fi
      mv -f "$partial" "$copy"
    fi
    printf '%s|%s\t%s\n' "$size" "$src" "$copy"
  done
done

find "$dir" -type f -mtime +30 -delete 2>/dev/null
exit 0
