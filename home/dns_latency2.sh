#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# DNS Latency Tester (UDP/53) - compara resolvers y recomienda el mejor
#
# Qué mide:
#   - El tiempo de respuesta (ms) de consultas DNS usando "dig".
#
# Cómo elige el "mejor DNS":
#   1) Menor MEDIANA (median)  -> más estable ante picos
#   2) Si empatan: menor PROMEDIO (avg)
#   3) Si empatan: menor P95 (percentil 95) -> “peor caso típico”
#
# Salida:
#   - Tabla por resolver: OK/FAIL, min, median, avg, max, p95
#   - Ranking final y recomendación
#
# Requisitos:
#   - dig (paquete: bind / bind-tools según distro)
#   - awk, sort, coreutils
#
# Uso:
#   ./dns-latency.sh
#   ./dns-latency.sh -n 20 -t 1
#   ./dns-latency.sh -r "1.1.1.1,8.8.8.8,9.9.9.9" -d "google.com,wikipedia.org"
#
# Notas importantes:
#   - DNS tiene caché. Para resultados más “justos”, este script consulta
#     varios dominios y repite múltiples veces.
#   - Esto prueba UDP/53 (no DoH/DoT). Si quieres DoH/DoT, dímelo.
# ==============================================================================

# Defaults
RUNS=10
TO=2
TRIES=1

RESOLVERS_DEFAULT="1.1.1.1,8.8.8.8,9.9.9.9,208.67.222.222"
DOMAINS_DEFAULT="google.com,cloudflare.com,wikipedia.org"

RESOLVERS="$RESOLVERS_DEFAULT"
DOMAINS="$DOMAINS_DEFAULT"

usage() {
  cat <<'EOF'
dns-latency.sh - DNS latency tester y recomendador de resolver

Opciones:
  -n, --runs N        Rondas por (resolver, dominio). Default: 10
  -t, --timeout S     Timeout por consulta en segundos. Default: 2
  -r, --resolvers CSV Lista de resolvers separados por coma
                      Ej: "1.1.1.1,8.8.8.8,9.9.9.9"
  -d, --domains CSV   Lista de dominios separados por coma
                      Ej: "google.com,wikipedia.org"
  -h, --help          Muestra esta ayuda

Ejemplos:
  ./dns-latency.sh
  ./dns-latency.sh -n 30 -t 1
  ./dns-latency.sh -r "192.168.1.1,1.1.1.1,8.8.8.8" -d "google.com,openwrt.org"

Interpretación rápida:
  median (mediana) baja = más consistente
  p95 bajo = menos “picos” (mejor peor-caso típico)
  FAIL alto = timeouts/errores (resolver inestable o filtrado)

EOF
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--runs) RUNS="${2:-}"; shift 2 ;;
    -t|--timeout) TO="${2:-}"; shift 2 ;;
    -r|--resolvers) RESOLVERS="${2:-}"; shift 2 ;;
    -d|--domains) DOMAINS="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Opción desconocida: $1"
      echo
      usage
      exit 1
      ;;
  esac
done

# Basic validation
is_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
is_int "$RUNS" || { echo "RUNS inválido: $RUNS"; exit 1; }
is_int "$TO" || { echo "TIMEOUT inválido: $TO"; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "Falta '$1' en el PATH"; exit 1; }; }
need dig
need awk
need sort
need wc
need head
need tail
need printf

# Convert CSV -> arrays
IFS=',' read -r -a RES_ARR <<< "$RESOLVERS"
IFS=',' read -r -a DOM_ARR <<< "$DOMAINS"

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
  local p="$1"
  awk -v p="$p" '
    {a[NR]=$1}
    END{
      n=NR
      if (n==0) {print "NA"; exit}
      # nearest-rank
      k=int((p/100)*n)
      if (((p/100)*n) > k) k=k+1
      if (k<1) k=1
      if (k>n) k=n
      print a[k]
    }'
}

fmt() { [[ "${1:-}" == "NA" || -z "${1:-}" ]] && printf "%s" "NA" || printf "%s" "$1"; }

print_row() {
  local r="$1" ok="$2" fail="$3" min="$4" med="$5" avg="$6" max="$7" p95="$8"
  printf "%-15s %5s %5s %7s %8s %8s %7s %7s\n" \
    "$r" "$ok" "$fail" "$(fmt "$min")" "$(fmt "$med")" "$(fmt "$avg")" "$(fmt "$max")" "$(fmt "$p95")"
}

echo "DNS Latency Tester"
echo "  runs=$RUNS  timeout=${TO}s  domains=${#DOM_ARR[@]}  resolvers=${#RES_ARR[@]}"
echo "  resolvers: $RESOLVERS"
echo "  domains:   $DOMAINS"
echo

RESULTS=() # resolver|ok|fail|min|median|avg|max|p95

printf "%-15s %5s %5s %7s %8s %8s %7s %7s\n" "Resolver" "OK" "FAIL" "min" "median" "avg" "max" "p95"
printf "%-15s %5s %5s %7s %8s %8s %7s %7s\n" "---------------" "-----" "-----" "-----" "------" "------" "-----" "-----"

for r in "${RES_ARR[@]}"; do
  all=()
  total=0
  ok=0
  fail=0

  for name in "${DOM_ARR[@]}"; do
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

