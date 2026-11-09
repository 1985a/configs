#!/usr/bin/env bash
# Busca en archlinux.org/news la noticia más reciente que pida intervención manual
# y la guarda en una caché que muestra ~/.zshrc al abrir la terminal.
# La ejecuta a diario el temporizador systemd archnews-check.timer.
set -uo pipefail

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}"
cache_file="$cache_dir/archnews-latest.txt"
mkdir -p "$cache_dir"

fetch() { curl -fsS --connect-timeout 5 --max-time 15 "$1"; }

if ! index=$(fetch https://archlinux.org/news/); then
    exit 0   # sin internet: se conserva la caché anterior
fi

mapfile -t urls < <(grep -Eo '<a href="/news/[^"]+"' <<< "$index" \
    | sed 's|<a href="\([^"]*\)"|https://archlinux.org\1|' | awk '!seen[$0]++')

result=$'\e[1;32mNo important Arch Linux news today.\e[0m'
for url in "${urls[@]}"; do
    content=$(fetch "$url") || continue
    if grep -qiE 'manual|attention|required|deprecated|intervention' <<< "$content"; then
        title=$(grep -oP '(?<=<title>).*?(?=</title>)' <<< "$content" | sed 's/ &mdash; Arch Linux//')
        result=$'\n\e[1;33m'"$title"$'\e[0m\n→ '"$url"$'\n'
        if command -v notify-send >/dev/null 2>&1; then
            notify-send --app-name="ArchLinux News" --urgency=normal \
                "Arch Linux News" "🚨 $title requiere atención" 2>/dev/null || true
        fi
        break
    fi
done

# escritura atómica: la terminal nunca lee un archivo a medias
tmp=$(mktemp "$cache_file.XXXXXX")
printf '%s\n' "$result" > "$tmp" && mv -f "$tmp" "$cache_file"
