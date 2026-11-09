#!/usr/bin/env bash
# Lista los nodos de PipeWire que piden una latencia concreta (node.latency) y los
# separa en baja (< umbral) y normal/alta.
#
# Uso: low-latency.sh [UMBRAL_MS]      (por defecto 5 ms)
#
# Sustituye a low-latency2.sh y low-latency3.sh: esta versión llama a pw-dump una
# sola vez y hace todo el cálculo en un único jq (low-latency3 llamaba a pw-dump
# tres veces por cada nodo).
set -euo pipefail

THRESHOLD_MS="${1:-5}"

for cmd in pw-dump jq; do
    command -v "$cmd" >/dev/null || { echo "Falta $cmd" >&2; exit 1; }
done

# Cada línea: ms <TAB> nombre <TAB> latencia original ("256/48000") <TAB> node.name
mapfile -t rows < <(pw-dump | jq -r '
    .[]
    | select(.type == "PipeWire:Interface:Node")
    | .info.props as $p
    | ($p["node.latency"] // empty) as $lat
    | ($lat | split("/")) as $fr
    | select(($fr | length) == 2 and ($fr[1] | tonumber? // 0) > 0)
    | [ (($fr[0] | tonumber) / ($fr[1] | tonumber) * 1000),
        ($p["application.name"] // $p["node.name"] // "Desconocido"),
        $lat,
        ($p["node.name"] // "") ]
    | @tsv')

etiqueta() {
    local n="${1,,}"
    case "$n" in
        *mpd*)       echo "🎵 [MPD]" ;;
        *retroarch*) echo "🕹️ [RetroArch]" ;;
        *firefox*)   echo "🌐 [Firefox]" ;;
        *chromium*)  echo "🌐 [Chromium]" ;;
        *brave*)     echo "🌐 [Brave]" ;;
        *mpv*)       echo "🎥 [MPV]" ;;
        *vlc*)       echo "📺 [VLC]" ;;
        *discord*)   echo "🎙️ [Discord]" ;;
        *)           echo "🎧" ;;
    esac
}

low=() high=()
for row in "${rows[@]}"; do
    IFS=$'\t' read -r ms name lat node <<< "$row"
    line="$(etiqueta "$name $node") $name → Latencia: $(printf '%.2f' "$ms") ms ($lat)"
    if awk -v a="$ms" -v b="$THRESHOLD_MS" 'BEGIN { exit !(a < b) }'; then
        low+=("$line")
    else
        high+=("$line")
    fi
done

echo "🔽 Aplicaciones con latencia baja (< $THRESHOLD_MS ms):"
(( ${#low[@]} )) && printf '%s\n' "${low[@]}"
echo
echo "🔼 Aplicaciones con latencia normal o alta (≥ $THRESHOLD_MS ms):"
(( ${#high[@]} )) && printf '%s\n' "${high[@]}"
exit 0
