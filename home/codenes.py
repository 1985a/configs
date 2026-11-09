#!/usr/bin/env python3

GG = "APZLGITYEOXUKSVN"

def parse_hex(value: str) -> int:
    """
    Acepta formatos como:
    BFE5
    $BFE5
    0xBFE5
    """
    value = value.strip().upper()

    if value.startswith("$"):
        value = value[1:]

    if value.startswith("0X"):
        value = value[2:]

    if not value:
        raise ValueError("Valor vacío.")

    return int(value, 16)


def encode_gg(address: int, value: int, compare: int | None = None) -> str:
    """
    Genera código Game Genie de NES.

    address:
        Dirección CPU en rango $8000-$FFFF.

    value:
        Byte nuevo que quieres escribir.

    compare:
        Byte original esperado. Si se usa, genera código de 8 letras.
        Si se omite, genera código de 6 letras.
    """

    if not (0x8000 <= address <= 0xFFFF):
        raise ValueError("La dirección debe estar entre $8000 y $FFFF. Game Genie no parchea RAM directa.")

    if not (0x00 <= value <= 0xFF):
        raise ValueError("El valor nuevo debe ser un byte entre $00 y $FF.")

    if compare is not None and not (0x00 <= compare <= 0xFF):
        raise ValueError("El compare debe ser un byte entre $00 y $FF.")

    if compare is None:
        n = [0] * 6

        n[0] = ((value >> 4) & 0x8) | ((value >> 0) & 0x7)
        n[1] = ((address >> 4) & 0x8) | ((value >> 4) & 0x7)
        n[2] = ((address >> 4) & 0x7)
        n[3] = ((address >> 0) & 0x8) | ((address >> 12) & 0x7)
        n[4] = ((address >> 8) & 0x8) | ((address >> 0) & 0x7)
        n[5] = ((value >> 0) & 0x8) | ((address >> 8) & 0x7)

    else:
        n = [0] * 8

        n[0] = ((value >> 4) & 0x8) | ((value >> 0) & 0x7)
        n[1] = ((address >> 4) & 0x8) | ((value >> 4) & 0x7)
        n[2] = ((address >> 4) & 0x7) | 0x8
        n[3] = ((address >> 0) & 0x8) | ((address >> 12) & 0x7)
        n[4] = ((address >> 8) & 0x8) | ((address >> 0) & 0x7)
        n[5] = ((compare >> 0) & 0x8) | ((address >> 8) & 0x7)
        n[6] = ((compare >> 4) & 0x8) | ((compare >> 0) & 0x7)
        n[7] = ((value >> 0) & 0x8) | ((compare >> 4) & 0x7)

    return "".join(GG[x] for x in n)


def main():
    print("Generador de códigos Game Genie para NES")
    print("----------------------------------------")
    print("Ejemplo de dirección: BFE5, $BFE5 o 0xBFE5")
    print("Ejemplo de valor: AD, 2C, EA, etc.")
    print()

    try:
        address_text = input("Dirección CPU/ROM ($8000-$FFFF): ")
        value_text = input("Valor nuevo byte: ")
        compare_text = input("Valor original / compare opcional, Enter para omitir: ")

        address = parse_hex(address_text)
        value = parse_hex(value_text)

        compare = None
        if compare_text.strip():
            compare = parse_hex(compare_text)

        code = encode_gg(address, value, compare)

        print()
        print("Resultado")
        print("---------")
        print(f"Dirección : ${address:04X}")
        print(f"Valor nuevo: ${value:02X}")

        if compare is not None:
            print(f"Compare    : ${compare:02X}")
            print("Tipo       : Game Genie 8 letras")
        else:
            print("Compare    : ninguno")
            print("Tipo       : Game Genie 6 letras")

        print()
        print(f"Código Game Genie: {code}")

    except ValueError as e:
        print()
        print(f"Error: {e}")


if __name__ == "__main__":
    main()
