#!/usr/bin/bash
sinks=$(pactl list sinks)
mute=$(echo "$sinks" | grep '^[[:space:]]Mute:' | head -n $(( $SINK + 1 )) | tail -n 1 | sed -e 's,.* \([0-9][0-9]*\)%.*,\1,' | awk '{print $2}')
vol=$(echo "$sinks" | grep '^[[:space:]]Volume:' | head -n $(( $SINK + 1 )) | tail -n 1| sed -e 's,.* \([0-9][0-9]*\)%.*,\1,')
if [ $mute == "yes" ]; then
  echo "  $vol"
else
  echo "  $vol"
fi

