#!/usr/bin/bash
ethstate=$(cat /sys/class/net/eth0/operstate)
wlanstate=$(cat /sys/class/net/wlan0/operstate)
if [ $ethstate == "up" ]; then
  echo  eth0
elif [ $wlanstate == "up" ]; then
  SSID=$(iwgetid -r)
  echo   $SSID
else
  echo \~ no connection
fi
