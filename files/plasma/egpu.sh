#!/bin/sh
# O KWin nao usa as tags mutter-device-* das regras de udev; elas servem para
# o mutter/GNOME. O KWin enumera todos os dispositivos DRM com KMS, e aqui isso
# inclui o display engine do Allwinner (card0). Sem isto o compositor Wayland
# pode escolher o card0 em vez da eGPU.
# Instalar em ~/.config/plasma-workspace/env/
export KWIN_DRM_DEVICES=/dev/dri/card2
