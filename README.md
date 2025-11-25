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

# Modo Estándar (Auto-organización por fecha/álbum)
./organizar_fotos.sh <origen> <destino> <originales>

# Modo Álbum Único (Forzar destino)
./organizar_fotos.sh --album <ruta_album> <destino> <originales>
```

### Modos de Funcionamiento

1.  **Modo Estándar**:
    *   Archivos en raíz -> `Destino/Año/Mes/`
    *   Archivos en subcarpetas -> `Destino/Año/Nombre_Subcarpeta/`

2.  **Modo Álbum Único (`--album`)**:
    *   Toma todo el contenido de `<ruta_album>` y lo mueve a `Destino/Nombre_Album_Sanitizado/`.
    *   Ignora la fecha para la estructura de carpetas.
    *   Útil para forzar la organización de un evento específico.

### Opciones
*   **Paralelismo**: Define `MAX_JOBS` para procesar varios videos a la vez.
    ```bash
    export MAX_JOBS=2
    ./organizar_fotos.sh ...
    ```
