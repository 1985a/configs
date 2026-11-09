#!/usr/bin/env python3
"""Lee e imprime los datos crudos de una palanca de cambios USB (VID 1020, PID 8864).

Requiere pyusb y permisos sobre el dispositivo (root o una regla udev).
Salir con Ctrl+C.
"""
import errno
import sys

import usb.core
import usb.util

VENDOR_ID = 0x1020
PRODUCT_ID = 0x8864


def main() -> int:
    dev = usb.core.find(idVendor=VENDOR_ID, idProduct=PRODUCT_ID)
    if dev is None:
        print("Dispositivo no encontrado", file=sys.stderr)
        return 1

    # libera la interfaz si el kernel la tiene tomada
    if dev.is_kernel_driver_active(0):
        dev.detach_kernel_driver(0)

    dev.set_configuration()
    endpoint = dev[0][(0, 0)][0]

    print("Leyendo datos del shifter... (Ctrl+C para salir)")
    try:
        while True:
            try:
                data = dev.read(endpoint.bEndpointAddress, endpoint.wMaxPacketSize, timeout=500)
                print("Datos:", list(data))
            except usb.core.USBError as e:
                if e.errno == errno.ETIMEDOUT:
                    continue
                raise
    except KeyboardInterrupt:
        pass
    finally:
        # devuelve el dispositivo al kernel al salir
        usb.util.dispose_resources(dev)
        try:
            dev.attach_kernel_driver(0)
        except usb.core.USBError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
