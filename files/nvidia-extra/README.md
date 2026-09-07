# libnvidia-allocator — o backend GBM que falta no arm64

`libnvidia-gl-580` do Ubuntu para **arm64** entrega 24 bibliotecas e **omite**
`libnvidia-allocator`, que é o backend GBM da NVIDIA. Sem ele nenhum compositor
Wayland consegue criar um `gbm_device` na GPU: o `libgbm` cai no backend do Mesa,
que tenta carregar um driver DRI para `10de:2584` e falha —

```
libEGL warning: pci id for fd 15: 10de:2584, driver (null)
libEGL warning: egl: failed to create dri2 screen
```

Não é bug do driver nem de configuração. É lacuna de empacotamento.

A biblioteca **existe** no instalador oficial aarch64 da NVIDIA, na mesma versão:

```bash
curl -O https://us.download.nvidia.com/XFree86/aarch64/580.142/NVIDIA-Linux-aarch64-580.142.run
sh NVIDIA-Linux-aarch64-580.142.run -x --target nvx
```

O manifesto do próprio instalador diz como registrá-la:

```
nvidia-drm_gbm.so 0000 GBM_BACKEND_LIB_SYMLINK NATIVE libnvidia-allocator.so.1 MODULE:nvalloc
```

Instalação:

```bash
L=/usr/lib/aarch64-linux-gnu
sudo install -m755 libnvidia-allocator.so.580.142 $L/
sudo ln -sf libnvidia-allocator.so.580.142 $L/libnvidia-allocator.so.1
sudo mkdir -p $L/gbm
sudo ln -sf ../libnvidia-allocator.so.1 $L/gbm/nvidia-drm_gbm.so
sudo ldconfig
```

Confirme que o backend é reconhecido:

```bash
nm -D --defined-only $L/gbm/nvidia-drm_gbm.so | grep gbmint_get_backend
```

**A versão tem de casar exatamente** com o driver instalado (`nvidia-smi`).
Como a instalação é manual e fora do `dpkg`, um upgrade pode removê-la sem
aviso — guarde uma cópia, como fazemos com os módulos do kernel.

Isto resolve a alocação de buffers. **Não** resolve os `Pageflip timed out!`,
que o KWin atribui ao driver `nvidia-drm` e que vêm acompanhados de crashes do
firmware GSP (`crashcat_queue_v1.c`). São problemas independentes.
