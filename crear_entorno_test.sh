#!/bin/bash
#
# Script para crear un entorno de prueba para organizar_fotos.sh
# (VERSIÓN ACTUALIZADA PARA H.264 Y EXIV2)
#

set -e

# Comprobamos herramientas para CREAR el entorno (usamos exiftool para escribir porque es fácil, aunque el script use exiv2 para leer)
for cmd in exiftool ffmpeg convert; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: El comando '$cmd' no se encuentra. Es necesario para crear el entorno de prueba."
        exit 1
    fi
done

TEST_ROOT="entorno_de_prueba"
echo "Limpiando entorno de prueba anterior..."
rm -rf "$TEST_ROOT"

echo "Creando nueva estructura de directorios en '$TEST_ROOT'..."
SOURCE_DIR="$TEST_ROOT/origen"
DEST_DIR="$TEST_ROOT/destino"
ORIGINALS_DIR="$TEST_ROOT/videos_originales"

mkdir -p "$SOURCE_DIR" "$DEST_DIR" "$ORIGINALS_DIR"
mkdir -p "$SOURCE_DIR/Album Viaje a la Playa"

echo "Creando archivos de prueba..."

# --- CASOS DE USO BÁSICOS ---
# Imagen en la raíz con fecha EXIF
convert -size 10x10 xc:blue "$SOURCE_DIR/foto con exif.jpg"
exiftool -q -overwrite_original -DateTimeOriginal="2023:05:15 10:00:00" "$SOURCE_DIR/foto con exif.jpg"

# Video en la raíz para conversión
ffmpeg -f lavfi -i testsrc=duration=1:size=160x120:rate=10 -pix_fmt yuv420p \
    -metadata creation_time="2024-02-20T11:00:00Z" -y "$SOURCE_DIR/video raiz.mp4" &> /dev/null

# Archivos en álbum
convert -size 10x10 xc:green "$SOURCE_DIR/Album Viaje a la Playa/en la arena.jpg"
exiftool -q -overwrite_original -DateTimeOriginal="2023:07:01 12:00:00" "$SOURCE_DIR/Album Viaje a la Playa/en la arena.jpg"

# --- NUEVOS CASOS DE PRUEBA ---

# 1. Video en origen que YA está convertido (sufijo _H264)
echo "  - Creando video ya convertido en origen..."
ffmpeg -f lavfi -i testsrc=duration=1:size=160x120:rate=10 -pix_fmt yuv420p \
    -y "$SOURCE_DIR/Album Viaje a la Playa/video ya procesado_H264.mp4" &> /dev/null

# 2. Video en origen cuyo destino convertido YA existe (debe ir a originales)
echo "  - Creando un video original y su 'doble' ya convertido en destino..."
mkdir -p "$DEST_DIR/2022/Vacaciones_Navidad"
touch "$DEST_DIR/2022/Vacaciones_Navidad/video_duplicado_H264.mp4"

mkdir -p "$SOURCE_DIR/Vacaciones Navidad"
ffmpeg -f lavfi -i testsrc=duration=1:size=160x120:rate=10 -pix_fmt yuv420p \
    -metadata creation_time="2022-12-25T18:00:00Z" \
    -y "$SOURCE_DIR/Vacaciones Navidad/video duplicado.mov" &> /dev/null

# 3. Caso de DUPLICADOS (Renombrado)
echo "  - Creando caso de colisión de nombres..."
# Creamos una imagen en destino
mkdir -p "$DEST_DIR/2023/05"
convert -size 10x10 xc:red "$DEST_DIR/2023/05/foto_con_exif.jpg"
# La imagen en origen "foto con exif.jpg" (creada arriba) irá a 2023/05 y se llamará igual (tras sanitizar).
# Debería renombrarse a foto_con_exif_1.jpg

echo ""
echo "¡Entorno de prueba creado con éxito!"
echo "---------------------------------------"
