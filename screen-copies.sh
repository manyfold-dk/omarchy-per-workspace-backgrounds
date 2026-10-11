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
# Fully opaque images become JPEG; images with any transparency become PNG.
# Copies unused for 30 days are deleted.

set -uo pipefail

dir=$1
IFS=, read -ra sizes <<<"$2"
shift 2
mkdir -p "$dir" || exit 1

for src in "$@"; do
  [[ -f $src ]] || continue
  read -r width height < <(magick identify -ping -format '%w %h\n' "$src[0]" 2>/dev/null | head -n1) || continue
  [[ $width =~ ^[0-9]+$ && $height =~ ^[0-9]+$ ]] || continue
  key=$(sha1sum <"$src" | cut -c1-16)

  for size in "${sizes[@]}"; do
    [[ $size =~ ^([0-9]+)x([0-9]+)$ ]] || continue
    screen_width=${BASH_REMATCH[1]}
    screen_height=${BASH_REMATCH[2]}
    # Only a file that has to shrink to cover the screen is worth a copy.
    (( width > screen_width && height > screen_height )) || continue

    copy=""
    for existing in "$dir/$key-$size.jpg" "$dir/$key-$size.png"; do
      [[ -s $existing ]] && { copy=$existing; break; }
    done
    if [[ -n $copy ]]; then
      touch -c "$copy"
    else
      # Scale first, then look at the pixels: an alpha channel says nothing,
      # since PNGs report one whether or not any pixel uses it.
      scaled="$dir/$key-$size.partial.$$.miff"
      if ! nice -n 10 magick "$src[0]" -resize "${size}^" -strip "miff:$scaled"; then
        rm -f "$scaled"
        continue
      fi
      if [[ $(magick identify -format '%[opaque]' "$scaled" 2>/dev/null) == True ]]; then
        format=jpg
      else
        format=png
      fi
      copy="$dir/$key-$size.$format"
      partial="$copy.partial.$$"
      if ! nice -n 10 magick "$scaled" -quality 95 "$format:$partial"; then
        rm -f "$scaled" "$partial"
        continue
      fi
      rm -f "$scaled"
      mv -f "$partial" "$copy"
    fi
    printf '%s|%s\t%s\n' "$size" "$src" "$copy"
  done
done

find "$dir" -type f -mtime +30 -delete 2>/dev/null
exit 0
