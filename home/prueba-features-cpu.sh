#!/usr/bin/env bash
# Comprueba con qué protecciones y optimizaciones se compiló un ejecutable:
# RELRO, pack-relative-relocs, CET, FORTIFY y uso de instrucciones AVX2 (ymm).
#
# Uso: prueba-features-cpu.sh [EJECUTABLE]     (por defecto /usr/local/bin/retroarch)
set -uo pipefail

f="${1:-/usr/local/bin/retroarch}"
[[ -f "$f" ]] || { echo "No existe: $f" >&2; exit 1; }

# RELRO completo + BIND_NOW (-z,relro -z,now)
if readelf -lW "$f" | grep -q GNU_RELRO && readelf -dW "$f" | grep -q BIND_NOW; then
    echo "RELRO completo: sí"
else
    echo "RELRO completo: no"
fi

# pack-relative-relocs
if readelf -dW "$f" | grep -q RELR; then
    echo "pack-relative-relocs: sí"
else
    echo "pack-relative-relocs: no"
fi

# CET (-fcf-protection): debe decir IBT, SHSTK
echo "CET: $(readelf -nW "$f" | grep -i 'x86 feature' || echo 'no')"

# FORTIFY: funciones "_chk" protegidas
echo "Funciones FORTIFY (_chk): $(nm -D "$f" 2>/dev/null | grep -c '_chk@')"

# Instrucciones AVX2 de Zen 3 (-march=znver3)
echo "Instrucciones con registros ymm (AVX/AVX2): $(objdump -d "$f" | grep -c ymm)"
