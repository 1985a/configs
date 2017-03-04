#!/usr/bin/sh
#AccuWeather (r) RSS weather tool for conky
#
#USAGE: weather.sh <locationcode>
#
#(c) Michael Seiler 2007

METRIC=1 #Should be 0 or 1; 0 for F, 1 for C

if [ -z $1 ]; then
    echo
    echo "USAGE: weather.sh <locationcode>"
    echo
    exit 0;
fi

curl -s --connect-timeout 15 http://rss.accuweather.com/rss/liveweather_rss.asp\?metric\=${METRIC}\&locCode\=$1| sed -n '/Currently:/ s/.*: \(.*\): \([-0-9]*\)\([CF]\).*/\2°C \L\1/p'|sed 's/A°/°/'

