#!/bin/bash
#
# Script para organizar fotos y videos, con comprobaciones para evitar reconversiones.
#
# Uso: ./organizar_fotos.sh /ruta/a/origen /ruta/a/destino /ruta/para/videos_originales
#

# --- CONFIGURACIÓN Y VALIDACIÓN INICIAL ---

set -e

if [ "$#" -ne 3 ]; then
    echo "Error: Se requieren 3 argumentos."
    echo "Uso: $0 <directorio_origen> <directorio_destino> <directorio_videos_originales>"
    exit 1
fi

SOURCE_DIR=$(realpath "$1")
DEST_DIR=$(realpath "$2")
ORIGINALS_DIR=$(realpath "$3")

for cmd in exiftool ffmpeg mediainfo nproc; do
    if ! command -v "$cmd" &> /dev/null; then echo "Error: El comando '$cmd' no se encuentra."; exit 1; fi
done

if [ ! -d "$SOURCE_DIR" ]; then echo "Error: El directorio de origen '$SOURCE_DIR' no existe."; exit 1; fi

mkdir -p "$DEST_DIR" "$ORIGINALS_DIR"
set +e

# --- BLOQUEO DE CONCURRENCIA ---
LOCK_FILE="/tmp/organizer.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || { echo "Otra instancia del script ya se está ejecutando." >&2; exit 1; }

# --- CONFIGURACIÓN ---
MAX_JOBS=1
NUM_CORES=$(nproc)
echo "INFO: Procesando 1 video a la vez (usando $NUM_CORES hilos por conversión)."
declare -A album_year_map

# --- DETECCIÓN DE GPU Y CÓDECS ---
USE_GPU=0
if [ -e "/dev/dri/renderD128" ]; then
    if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "h264_vaapi"; then
        USE_GPU=1
        echo "INFO: GPU Intel detectada y códec h264_vaapi disponible. Se usará aceleración por hardware."
    else
        echo "AVISO: GPU Intel detectada pero no se encontró el códec 'h264_vaapi'. Se usará CPU."
    fi
else
    echo "INFO: No se detectó GPU Intel (/dev/dri/renderD128). Se usará CPU."
fi

# --- DEFINICIÓN DE FUNCIONES --- (La función process_video no cambia)

get_file_date() {
    local file="$1"
    local date_str=""
    date_str=$(exiftool -q -p '$DateTimeOriginal' -d '%Y-%m-%d' "$file" 2>/dev/null); if [[ "$date_str" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then echo "$date_str"; return; fi
    date_str=$(exiftool -q -p '$CreateDate' -d '%Y-%m-%d' "$file" 2>/dev/null); if [[ "$date_str" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then echo "$date_str"; return; fi
    date_str=$(mediainfo --Output="General;%Encoded_Date%" "$file" 2>/dev/null | sed 's/UTC //g' | cut -d' ' -f1); if [[ "$date_str" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then echo "$date_str"; return; fi
    local filename=$(basename "$file"); if [[ "$filename" =~ ([0-9]{4})[-_]?([0-9]{2})[-_]?([0-9]{2}) ]]; then echo "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"; return; fi
    if [[ "$filename" =~ ([0-9]{2})[-_]?([0-9]{2})[-_]?([0-9]{4}) ]]; then echo "${BASH_REMATCH[3]}-${BASH_REMATCH[2]}-${BASH_REMATCH[1]}"; return; fi
    date -r "$file" "+%Y-%m-%d"
}

process_video() {
    local file="$1"
    local dest_path="$2"
    local originals_dir="$3"
    local num_threads="$4"
    local ext="${file##*.}"
    local base_name_raw; base_name_raw=$(basename "$file" ."$ext")
    local base_name_sanitized=${base_name_raw// /_}
    echo "INICIANDO conversión de video (PID $$): $(basename "$file")"
    local TMP_DIR; TMP_DIR=$(mktemp -d); trap 'rm -rf "$TMP_DIR"' RETURN
    local output_file_temp="$TMP_DIR/${base_name_raw}_H264.mp4"
    
    local ffmpeg_cmd=(ffmpeg -nostdin -i "$file")
    
    if [ "$USE_GPU" -eq 1 ]; then
        # Configuración GPU: H.264 VAAPI, QP 28
        ffmpeg_cmd+=(-vaapi_device /dev/dri/renderD128 -vf "format=nv12,hwupload,scale_vaapi=w=-2:h=1080" -c:v h264_vaapi -qp 28)
    else
        # Configuración CPU: libx264, CRF 24, preset veryfast
        ffmpeg_cmd+=(-vf "scale=-2:1080" -c:v libx264 -crf 24 -preset veryfast)
    fi

    # Configuración común: Audio AAC 128k, Metadata, Movflags
    ffmpeg_cmd+=(-c:a aac -b:a 128k -map_metadata 0 -movflags +faststart -y "$output_file_temp")

    if "${ffmpeg_cmd[@]}" &> /dev/null; then
        echo "  -> Conversión de '$(basename "$file")' exitosa."
        local final_dest_file="$dest_path/${base_name_sanitized}_H264.mp4"
        mv -n "$output_file_temp" "$final_dest_file"
        echo "  -> Moviendo convertido a: $final_dest_file"
        local original_filename_raw=$(basename "$file"); local original_filename_sanitized=${original_filename_raw// /_}
        mv -n "$file" "$originals_dir/$original_filename_sanitized"
        echo "  -> Moviendo original a: $originals_dir/$original_filename_sanitized"
    else
        echo "ERROR: Falló la conversión de '$(basename "$file")'. El original se dejará en su sitio."
    fi
    trap - RETURN; rm -rf "$TMP_DIR"
    echo "FINALIZADA conversión de video (PID $$): $(basename "$file")"
}
export -f process_video get_file_date

# --- PROCESAMIENTO PRINCIPAL ---
echo "Iniciando la organización de '$SOURCE_DIR'..."
echo "-------------------------------------------"
while IFS= read -r file; do
    if [ -z "$file" ]; then continue; fi
    ext_lower=$(echo "${file##*.}" | tr '[:upper:]' '[:lower:]')
    file_type=""
    case "$ext_lower" in
        jpg|jpeg|gif|png|heic|cr2|crw|nef|orf|raw|dng|arw) file_type="image" ;;
        mov|3gp|avi|mkv|mp4|mpg|mpeg|wmv|flv|webm|m4v) file_type="video" ;;
        *) echo "OMITIENDO: Archivo no reconocido '$file'"; continue ;;
    esac
    file_date=$(get_file_date "$file")
    if [ -z "$file_date" ]; then echo "ERROR: No se pudo determinar la fecha para '$file'. Omitiendo."; continue; fi
    year=$(echo "$file_date" | cut -d'-' -f1); month=$(echo "$file_date" | cut -d'-' -f2); file_dir=$(dirname "$file")
    
    if [ "$file_dir" == "$SOURCE_DIR" ]; then
        dest_path="$DEST_DIR/$year/$month"
    else
        album_name_raw=$(basename "$file_dir"); album_name_sanitized=${album_name_raw// /_}
        album_year=${album_year_map[$file_dir]}
        if [ -z "$album_year" ]; then
            album_year=$year; album_year_map[$file_dir]=$album_year
            echo "INFO: Álbum '$album_name_raw' ('$album_name_sanitized') asignado al año $album_year."
        fi
        dest_path="$DEST_DIR/$album_year/$album_name_sanitized"
    fi
    mkdir -p "$dest_path"
    
    filename_raw=$(basename "$file"); filename_sanitized=${filename_raw// /_}

    if [ "$file_type" == "image" ]; then
        final_dest_file="$dest_path/$filename_sanitized"
        echo "MOVIENDO IMAGEN: $filename_raw -> $final_dest_file"
        mv -n "$file" "$final_dest_file"

    elif [ "$file_type" == "video" ]; then
        # === INICIO DE LOS NUEVOS CAMBIOS ===

        # 1. Comprobar si el archivo en origen YA es H264 (convertido por este script). Si es así, solo moverlo.
        if [[ "$filename_raw" == *"_H264."* ]]; then
            final_dest_file="$dest_path/$filename_sanitized"
            echo "SALTANDO (ya convertido): Moviendo directamente $filename_raw -> $final_dest_file"
            mv -n "$file" "$final_dest_file"
            continue # Pasar al siguiente archivo
        fi
        
        # 2. Comprobar si el archivo convertido YA existe en el destino.
        ext="${file##*.}"
        base_name_raw=$(basename "$file" ."$ext")
        base_name_sanitized=${base_name_raw// /_}
        potential_target_file="$dest_path/${base_name_sanitized}_H264.mp4"

        if [ -f "$potential_target_file" ]; then
            echo "SALTANDO (destino ya existe): El archivo '$potential_target_file' ya existe."
            original_filename_sanitized=${filename_raw// /_}
            mv -n "$file" "$ORIGINALS_DIR/$original_filename_sanitized"
            echo "  -> Moviendo original '$filename_raw' a $ORIGINALS_DIR/"
            continue # Pasar al siguiente archivo
        fi

        # === FIN DE LOS NUEVOS CAMBIOS ===

        # Si ninguna de las condiciones anteriores se cumplió, poner en cola para convertir.
        if (( $(jobs -p | wc -l) >= MAX_JOBS )); then wait -n; fi
        process_video "$file" "$dest_path" "$ORIGINALS_DIR" "$NUM_CORES" &
    fi
done < <(find "$SOURCE_DIR" -type f)

# --- FINALIZACIÓN ---
echo "-------------------------------------------"
echo "Todos los archivos han sido puestos en cola. Esperando a que terminen las conversiones restantes..."
wait
echo "Todas las tareas han finalizado."
echo "Proceso de organización completado."
