#!/usr/bin/bash
pactl list sinks | grep '^[[:space:]]Mute:'
