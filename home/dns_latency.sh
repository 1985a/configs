#!/usr/bin/env bash
set -euo pipefail

# =========================
# Configuración
# =========================
RESOLVERS=(
  "1.1.1.1"
  "8.8.8.8"
  "9.9.9.9"
  "208.67.222.222"
)

NAMES=(
  "google.com"
  "cloudflare.com"
  "wikipedia.org"
)

RUNS="${1:-10}"   # rondas por (resolver,nombre)
TO="${2:-2}"      # timeout por consulta (seg)
TRIES=1

# =========================
# Dependencias
# =========================
need() { command -v "$1" >/dev/null 2>&1 || { echo "Falta '$1'"; exit 1; }; }
need dig
need awk
need sort
need wc
need head
need tail

query_time_ms() {
  local server="$1" name="$2"
  dig @"$server" "$name" +tries="$TRIES" +timeout="$TO" +stats 2>/dev/null \
    | awk -F': ' '/Query time/ {gsub(/ msec/,"",$2); print $2; exit}'
}

median_from_sorted() {
  awk '
    {a[NR]=$1}
    END{
      if (NR==0) {print "NA"; exit}
      if (NR%2==1) print a[(NR+1)/2];
      else print (a[NR/2]+a[NR/2+1])/2
    }'
}

percentile_from_sorted() {
  # Uso: percentile_from_sorted 95
  # Entrada: lista ordenada numéricamente, una por línea
  local p="${1}"
  awk -v p="$p" '
    {a[NR]=$1}
    END{
      n=NR
      if (n==0) {print "NA"; exit}
      # método "nearest rank"
      k=int((p/100)*n)
      if (((p/100)*n) > k) k=k+1
      if (k<1) k=1
      if (k>n) k=n
      print a[k]
    }'
}

fmt() { # formatea NA/valor
  [[ "${1:-}" == "NA" || -z "${1:-}" ]] && printf "%s" "NA" || printf "%s" "$1"
}

echo "RUNS=$RUNS  timeout=${TO}s  domains=${#NAMES[@]}  resolvers=${#RESOLVERS[@]}"
echo

# Guardamos resultados para ranking final:
# líneas: resolver|ok|fail|min|median|avg|max|p95
RESULTS=()

print_row() {
  local r="$1" ok="$2" fail="$3" min="$4" med="$5" avg="$6" max="$7" p95="$8"
  printf "%-15s %5s %5s %7s %8s %8s %7s %7s\n" \
    "$r" "$ok" "$fail" "$(fmt "$min")" "$(fmt "$med")" "$(fmt "$avg")" "$(fmt "$max")" "$(fmt "$p95")"
}

printf "%-15s %5s %5s %7s %8s %8s %7s %7s\n" "Resolver" "OK" "FAIL" "min" "median" "avg" "max" "p95"
printf "%-15s %5s %5s %7s %8s %8s %7s %7s\n" "---------------" "-----" "-----" "-----" "------" "------" "-----" "-----"

for r in "${RESOLVERS[@]}"; do
  all=()
  total=0
  ok=0
  fail=0

  for name in "${NAMES[@]}"; do
    for ((i=1;i<=RUNS;i++)); do
      ms="$(query_time_ms "$r" "$name" || true)"
      if [[ -n "${ms:-}" && "$ms" =~ ^[0-9]+$ ]]; then
        all+=("$ms")
        total=$((total + ms))
        ok=$((ok + 1))
      else
        fail=$((fail + 1))
      fi
    done
  done

  if (( ok == 0 )); then
    # sin respuestas
    RESULTS+=("${r}|0|${fail}|NA|NA|NA|NA|NA")
    print_row "$r" 0 "$fail" NA NA NA NA NA
    continue
  fi

  avg="$(awk -v t="$total" -v n="$ok" 'BEGIN{printf "%.2f", t/n}')"
  sorted="$(printf "%s\n" "${all[@]}" | sort -n)"
  min="$(printf "%s\n" "$sorted" | head -n1)"
  max="$(printf "%s\n" "$sorted" | tail -n1)"
  med="$(printf "%s\n" "$sorted" | median_from_sorted)"
  p95="$(printf "%s\n" "$sorted" | percentile_from_sorted 95)"

  RESULTS+=("${r}|${ok}|${fail}|${min}|${med}|${avg}|${max}|${p95}")
  print_row "$r" "$ok" "$fail" "$min" "$med" "$avg" "$max" "$p95"
done

echo
echo "Ranking final (menor median -> menor avg -> menor p95):"

# Ordenamos con awk/sort:
# - ignoramos los que tengan median=NA
# - usamos claves numéricas: median, avg, p95
ranked="$(
  printf "%s\n" "${RESULTS[@]}" \
  | awk -F'|' '$5!="NA"{print}' \
  | awk -F'|' '{printf "%s|%s|%s|%s\n",$1,$5,$6,$8}' \
  | sort -t'|' -k2,2n -k3,3n -k4,4n
)"

if [[ -z "${ranked:-}" ]]; then
  echo "No hubo respuestas de ningún resolver (todo timeout)."
  exit 0
fi

# Imprime ranking bonito
i=1
while IFS='|' read -r r med avg p95; do
  printf "  %d) %-15s  median=%sms  avg=%sms  p95=%sms\n" "$i" "$r" "$med" "$avg" "$p95"
  i=$((i+1))
done <<< "$ranked"

best="$(printf "%s\n" "$ranked" | head -n1 | awk -F'|' '{print $1}')"
best_med="$(printf "%s\n" "$ranked" | head -n1 | awk -F'|' '{print $2}')"
best_avg="$(printf "%s\n" "$ranked" | head -n1 | awk -F'|' '{print $3}')"
best_p95="$(printf "%s\n" "$ranked" | head -n1 | awk -F'|' '{print $4}')"

echo
echo "✅ Mejor DNS recomendado: $best  (median=${best_med}ms, avg=${best_avg}ms, p95=${best_p95}ms)"

