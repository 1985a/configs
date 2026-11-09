#!/usr/bin/env bash
# Dynamic hwmon resolver for Conky.
# Avoids hard-coding /sys/class/hwmon/hwmonN indexes.
# Uso: conky_hwmon_auto.sh {temps|fans|watts}

set -u

HWMON_ROOT="${HWMON_ROOT:-/sys/class/hwmon}"

read_text() {
    local f="$1" v=""
    [[ -r "$f" ]] || return 1
    IFS= read -r v < "$f" || return 1
    printf '%s' "$v"
}

find_chip_exact() {
    local wanted="$1" d name
    for d in "$HWMON_ROOT"/hwmon*; do
        [[ -d "$d" && -r "$d/name" ]] || continue
        name="$(read_text "$d/name")" || continue
        [[ "$name" == "$wanted" ]] && { printf '%s\n' "$d"; return 0; }
    done
    return 1
}

find_chip_pattern() {
    local pattern="$1" d name
    for d in "$HWMON_ROOT"/hwmon*; do
        [[ -d "$d" && -r "$d/name" ]] || continue
        name="$(read_text "$d/name")" || continue
        # shellcheck disable=SC2053  # $pattern es un comodín a propósito (p. ej. nct67*)
        [[ "$name" == $pattern ]] && { printf '%s\n' "$d"; return 0; }
    done
    return 1
}

find_input_by_label_in_chip() {
    local chip="$1" prefix="$2" wanted="$3" label label_value input
    for label in "$chip"/"${prefix}"*_label; do
        [[ -r "$label" ]] || continue
        label_value="$(read_text "$label")" || continue
        [[ "$label_value" == "$wanted" ]] || continue
        input="${label%_label}_input"
        [[ -r "$input" ]] || continue
        printf '%s\n' "$input"
        return 0
    done
    return 1
}

find_input_by_label_global() {
    local prefix="$1" wanted="$2" d input
    for d in "$HWMON_ROOT"/hwmon*; do
        [[ -d "$d" ]] || continue
        input="$(find_input_by_label_in_chip "$d" "$prefix" "$wanted" 2>/dev/null)" || continue
        [[ -n "$input" ]] && { printf '%s\n' "$input"; return 0; }
    done
    return 1
}

read_int_or_na() {
    local f="$1" v=""
    [[ -r "$f" ]] || { printf 'N/A'; return 0; }
    IFS= read -r v < "$f" || { printf 'N/A'; return 0; }
    [[ "$v" =~ ^-?[0-9]+$ ]] || { printf 'N/A'; return 0; }
    printf '%s' "$v"
}

read_temp_c_or_na() {
    local f="$1" v=""
    [[ -r "$f" ]] || { printf 'N/A'; return 0; }
    IFS= read -r v < "$f" || { printf 'N/A'; return 0; }
    [[ "$v" =~ ^-?[0-9]+$ ]] || { printf 'N/A'; return 0; }
    printf '%d' "$((v / 1000))"
}

cpu_temp_file() {
    local chip="$1" label="$2" fallback="$3" f=""
    f="$(find_input_by_label_in_chip "$chip" temp "$label" 2>/dev/null)" || true
    if [[ -n "$f" ]]; then
        printf '%s\n' "$f"
    elif [[ -r "$chip/$fallback" ]]; then
        printf '%s\n' "$chip/$fallback"
    else
        return 1
    fi
}

show_temps() {
    local chip="" f_ccd="" f_die="" f_ctl="" probe=""

    chip="$(find_chip_exact zenpower 2>/dev/null)" || true
    [[ -n "$chip" ]] || chip="$(find_chip_exact k10temp 2>/dev/null)" || true

    if [[ -z "$chip" ]]; then
        probe="$(find_input_by_label_global temp Tdie 2>/dev/null)" || true
        [[ -n "$probe" ]] && chip="$(dirname "$probe")"
    fi

    if [[ -z "$chip" ]]; then
        printf 'N/A/N/A/N/A'
        return 0
    fi

    f_ccd="$(cpu_temp_file "$chip" Tccd1 temp3_input 2>/dev/null)" || true
    f_die="$(cpu_temp_file "$chip" Tdie temp1_input 2>/dev/null)" || true
    f_ctl="$(cpu_temp_file "$chip" Tctl temp2_input 2>/dev/null)" || true

    printf '%s/%s/%s' \
        "$(read_temp_c_or_na "$f_ccd")" \
        "$(read_temp_c_or_na "$f_die")" \
        "$(read_temp_c_or_na "$f_ctl")"
}

show_fans() {
    local chip="" f2 f5 f3 f6

    chip="$(find_chip_exact nct6795 2>/dev/null)" || true
    [[ -n "$chip" ]] || chip="$(find_chip_pattern 'nct67*' 2>/dev/null)" || true

    if [[ -z "$chip" ]]; then
        printf 'N/A RPM | N/A RPM | N/A RPM | N/A RPM'
        return 0
    fi

    f2="$(read_int_or_na "$chip/fan2_input")"
    f5="$(read_int_or_na "$chip/fan5_input")"
    f3="$(read_int_or_na "$chip/fan3_input")"
    f6="$(read_int_or_na "$chip/fan6_input")"

    printf '%s RPM | %s RPM | %s RPM | %s RPM' "$f2" "$f5" "$f3" "$f6"
}

show_watts() {
    local f="" chip="" v=""

    f="$(find_input_by_label_global power SVI2_P_Core 2>/dev/null)" || true

    if [[ -z "$f" ]]; then
        chip="$(find_chip_exact zenpower 2>/dev/null)" || true
        [[ -n "$chip" && -r "$chip/power1_input" ]] && f="$chip/power1_input"
    fi

    if [[ -z "$f" || ! -r "$f" ]]; then
        printf 'CPU N/A'
        return 0
    fi

    IFS= read -r v < "$f" || { printf 'CPU N/A'; return 0; }
    [[ "$v" =~ ^[0-9]+$ ]] || { printf 'CPU N/A'; return 0; }

    printf 'CPU %dW' "$((v / 1000000))"
}

case "${1:-}" in
    temps) show_temps ;;
    fans)  show_fans ;;
    watts) show_watts ;;
    *)
        printf 'Uso: %s {temps|fans|watts}\n' "${0##*/}" >&2
        exit 2
        ;;
esac
