# momentario-bash

Script para organizar álbumes de fotos y convertir videos a H.264 (con aceleración GPU Intel si está disponible).

## Requisitos

Instalar dependencias (Debian/Ubuntu):
```bash
sudo apt install exiv2 ffmpeg mediainfo
```

## Configuración GPU (Intel)

Para usar aceleración por hardware (`h264_vaapi`), asegúrate de tener los drivers instalados y acceso al dispositivo:

1.  Instalar drivers:
    ```bash
    sudo apt install intel-media-va-driver-non-free
    ```
2.  Verificar dispositivo:
    Debe existir `/dev/dri/renderD128`.

Si no se detecta GPU, el script usará automáticamente la CPU.

## Uso

```bash
chmod +x organizar_fotos.sh
./organizar_fotos.sh <origen> <destino> <originales>
```

### Opciones
*   **Paralelismo**: Define `MAX_JOBS` para procesar varios videos a la vez.
    ```bash
    export MAX_JOBS=2
    ./organizar_fotos.sh ...
    ```
