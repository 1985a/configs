# configs

Mis configuraciones de Arch Linux con **sway** (Wayland): barra de estado hecha con
**conky**, música con **mpd + ncmpcpp**, terminal **kitty + tmux + zsh**, y los scripts
que uso a diario.

> La versión anterior (i3, irssi, vim… de 2016-2018) sigue disponible en la etiqueta
> [`legacy-2016`](../../tree/legacy-2016).

## Instalar en otra máquina

```sh
git clone https://github.com/1985a/configs.git ~/GIT/configs
cd ~/GIT/configs

# 1. paquetes
sudo pacman -S --needed $(grep -v '^#' paquetes.txt | cut -d' ' -f1)

# 2. oh-my-zsh (no es un paquete de Arch)
git clone https://github.com/ohmyzsh/ohmyzsh.git ~/.oh-my-zsh

# 3. ver qué se va a hacer, y después instalar
./install.sh --dry-run
./install.sh
```

`install.sh` crea **enlaces simbólicos** desde tu home hacia este repositorio, así lo que
cambies en tu sistema queda listo para hacer `git commit`. Con `--copy` copia los
archivos en lugar de enlazarlos. Antes de reemplazar cualquier archivo lo guarda en
`~/.local/state/configs-backup/FECHA/`, y se puede ejecutar varias veces sin problema.

Después recarga sway con <kbd>Super</kbd>+<kbd>z</kbd>.

### Archivos privados (no se suben)

Los datos personales no están en el repositorio. Cada script los busca en tu máquina;
en `local.example/` hay plantillas:

| Archivo en tu máquina | Para qué | Plantilla |
|---|---|---|
| `~/.config/weather-location` | ciudad del clima en la barra (si no existe, wttr.in usa la ubicación aproximada de tu IP) | `local.example/weather-location` |
| `~/.config/zsh/local.zsh` | clave de codebin, wifi de invitados (`qrwifi`), coordenadas (`filtroazul`) | `local.example/zsh-local.zsh` |
| `~/.config/home-scripts.env` | IPs de tu red para los scripts de puente, TV y streaming | `local.example/home-scripts.env` |
| `~/.gitconfig.local` | tu nombre y correo de git (`install.sh` lo crea a partir de tu `.gitconfig` anterior) | — |

### Cosas propias de este equipo

- `sway/config` tiene los nombres de los monitores (`DP-2`, `DP-3`), sus modos y la ruta
  del perfil de color `.icm` del Samsung G5. En otro equipo ajusta esas líneas
  (`swaymsg -t get_outputs` muestra los nombres).
- La barra lee los sensores por su nombre (`zenpower`/`k10temp` para la CPU, `nct67xx`
  para los ventiladores, `nvidia-smi` para la GPU): con otro hardware los valores que no
  existan salen como `N/A`.
- `conky` está compilado a mano en `/usr/local/bin`; el paquete `conky` de Arch también sirve.
- `aa.sh` es un *hook* de suspensión y va en `/usr/lib/systemd/system-sleep/` (como root):
  `sudo install -m755 ~/aa.sh /usr/lib/systemd/system-sleep/sway-dp-fix`

## Qué hay y adónde va

| En el repositorio | Se instala en | Qué es |
|---|---|---|
| `sway/config` | `~/.config/i3/config` | configuración de sway |
| `conky/conkyrc.json`, `conky/conky-wrapper` | `~/.conkyrc.json`, `~/conky-wrapper` | barra de estado (JSON para swaybar) |
| `barra/` | `~/.scripts/scripts/` | scripts que usa la barra: sensores, GPU, MPD, volumen, Bluetooth, clima, noticias de Arch |
| `mpd/mpd.conf` | `~/.mpd/mpd.conf` | MPD con salida PipeWire |
| `ncmpcpp/` | `~/.ncmpcpp/` | config, carátulas (`cover.sh`, `cover_pane.sh`) y letras desde lrclib.net |
| `bin/` | `~/.local/bin/` | notificación de canción, ncmpcpp con carátula en tmux, guardián del selector de archivos GTK |
| `mako/` | `~/.config/mako/`, `~/.config/systemd/user/mako.service.d/` | notificaciones |
| `kitty/`, `tmux/` | `~/.config/kitty/kitty.conf`, `~/.tmux.conf` | terminal |
| `zsh/`, `shell/` | `~/.zshrc`, `~/.zprofile`, `~/.zshenv`, `~/.profile`, `~/.bash_profile`, `~/.bashrc` | shells |
| `x11/` | `~/.Xresources`, `~/.scripts/dir_colors` | colores (Solarized) |
| `git/gitconfig` | `~/.gitconfig` | git (sin datos personales) |
| `systemd/user/` | `~/.config/systemd/user/` | temporizador diario de noticias de Arch |
| `fonts/` | `~/.local/share/fonts/` | Droid Sans Mono Powerline Nerd (la de la barra) |
| `home/` | `~/` | scripts sueltos de mi home (lista abajo) |

## Scripts de `home/`

Todos llevan al principio un comentario con qué hacen y cómo se usan. Los que tocan el
sistema (IRQs, red, puentes) piden `sudo`.

**Audio y latencia:** `aislar-irqs-audio.sh`, `balance_irqs.sh`, `balance-irq2.sh`,
`irq_cpu_map.sh`, `realaudio.sh`, `klk.sh`, `low-latency.sh`, `ver-latenciaaudio.sh`,
`pci_latency.sh`, `audio_audit_pipewire.sh`, `duck-audio-setup.sh`

**CPU, GPU y rendimiento:** `info-cpu.sh`, `info-cpu-ryzen.sh`, `nvidia_ver.sh`,
`sss.sh`, `detect_hwmon.sh`, `prueba-features-cpu.sh`, `benchmark.sh`, `benchmark2.sh`,
`opt_system.sh`

**Red y máquinas virtuales:** `bridge_qemu2.sh`, `puente-win10.sh`, `bridge-win10.sh`,
`bridge_qemu-disable.sh`, `script-net.sh`, `checkar-vhost.sh`, `low_latency_cable0.sh`,
`dns_latency.sh`, `dns_latency2.sh`, `mountimgVHD.sh`

**Router OpenWrt** (se copian y ejecutan en el router): `dns_openwrt.sh`,
`nft_dns_redirect.sh`, `bufferbloat_test.sh`, `irq_tune_dlx36.sh`,
`optimizar_irqs_dynalink.sh`

**Proxmox (honeypots):** `create-contener.sh` (SSH falso), `fake-rdp-server.sh` (RDP falso)

**Música y vídeo:** `editar-tag-actual.sh`, `test-mpd.sh`, `ver-youtube.sh`,
`youtube2.sh`, `youtube3.sh`

**Mandos:** `joystick-detect.sh`, `joystickv.sh`, `joyviz.sh`, `joyviz2.sh`, `shifter.py`

**Varios:** `aa.sh` (hook de suspensión), `monitor-off-on.sh`, `actualizar_enlaces.sh`,
`purgar-jdownloader.sh`, `quitar_apps_tv.sh`, `reporte-kde.sh`, `zshistory.sh`,
`codenes.py` (códigos Game Genie de NES), `.statusline.sh`, `.vocab` + `.vocabscript`
(palabra en inglés al abrir la terminal)

## Revisión de 2026

Todos los scripts pasan [shellcheck](https://www.shellcheck.net/) sin avisos. Errores
corregidos que afectaban al funcionamiento:

- **Barra:** el volumen se leía de la primera salida de audio y no de la predeterminada
  (marcaba 100 % con la real al 84 %); los iconos del clima elegían lluvia para
  "light snow showers" o "rain with thunder"; Bluetooth hacía 3 llamadas por dispositivo
  cada 2 s; la posición del texto de MPD se guardaba en `/tmp`.
- **sway:** la tecla de suspender del modo sistema no cerraba las comillas y usaba
  `$Lock` sin definir; bloquear y salir usaban `i3lock-fancy` e `i3-msg` (de X11); faltaban
  comas en varias reglas `for_window`; las opciones de rofi ya no existen en rofi 2.
- **zsh:** `umask=022` creaba una variable en vez de cambiar la umask; `-D_FORTYFY_SOURCE`
  (mal escrito) no activaba nada; el alias `scanport` no podía recibir argumentos; al abrir
  cada terminal se hacía una petición a archlinux.org.
- **tmux:** ejecutaba `power-daemon` (no existe) en lugar de `powerline-daemon`.
- **Scripts:** `aislar-irqs-audio.sh` movía IRQs equivocadas (los números fijos ya eran
  de la NVIDIA y del wifi); `balance-irq2.sh` se cortaba en la primera vuelta por
  `set -e`; `aa.sh` nunca encontraba sway; `opt_system.sh` tenía finales de línea de
  Windows y no arrancaba; `editar-tag-actual.sh` fallaba con títulos con apóstrofo;
  `klk.sh` y `ver-latenciaaudio.sh` no veían los procesos FIFO; `test-mpd.sh` pisaba la
  variable `SECONDS` de bash; `zshistory.sh` lanzaba 3 procesos por línea (ahora tarda
  0,2 s con 500 000 líneas); `mountimgVHD.sh` copiaba a una ruta de ejemplo sin rellenar;
  `create-contener.sh` ponía `123456` como contraseña root por defecto.
- **Privacidad:** IPs, MAC, dominio, coordenadas, claves de API y contraseñas pasaron a
  los archivos locales de arriba.

Fuera del repositorio a propósito: `recuperar-user-vigilancia.sh` (de otro proyecto),
`script-openwrt.sh` (copia idéntica de `nft_dns_redirect.sh`), `low-latency2.sh` y
`low-latency3.sh` (los reemplaza `low-latency.sh`), `~/.ncmpcpp/show_cover.sh` (viejo
y con una API key dentro), binarios compilados y archivos de datos.

## Licencia

GPL-2.0, ver [LICENSE](LICENSE).
