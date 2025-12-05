#!/bin/bash
#
# Script para organizar fotos y videos, con comprobaciones para evitar reconversiones.
# Optimizado para usar exiv2, paralelismo configurable y mejor manejo de álbumes.
#
# Uso: ./organizar_fotos.sh /ruta/a/origen /ruta/a/destino /ruta/para/videos_originales

# --- CONFIGURACIÓN Y VALIDACIÓN INICIAL ---

set -e

SINGLE_ALBUM_MODE=0

if [ "$1" == "--album" ]; then
    SINGLE_ALBUM_MODE=1
    shift
fi

if [ "$#" -ne 3 ]; then
    echo "Error: Se requieren 3 argumentos."
    if [ "$SINGLE_ALBUM_MODE" -eq 1 ]; then
        echo "Uso: $0 --album <directorio_album> <directorio_destino> <directorio_videos_originales>"
    else
        echo "Uso: $0 <directorio_origen> <directorio_destino> <directorio_videos_originales>"
    fi
    exit 1
fi

SOURCE_DIR=$(realpath "$1")
DEST_DIR=$(realpath "$2")
ORIGINALS_DIR=$(realpath "$3")

if [ "$SINGLE_ALBUM_MODE" -eq 1 ]; then
    ALBUM_NAME_RAW=$(basename "$SOURCE_DIR")
    ALBUM_NAME_SANITIZED=${ALBUM_NAME_RAW// /_}
    echo "INFO: Modo Álbum Único activado."
    echo "INFO: Álbum: $ALBUM_NAME_SANITIZED"
    echo "INFO: Destino: $DEST_DIR/$ALBUM_NAME_SANITIZED"
fi

# Configuración de LOG
LOG_FILE="organizer_$(date +%Y-%m-%d).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== INICIO DEL PROCESO: $(date) ==="

# Verificación de dependencias (exiv2 en lugar de exiftool)
for cmd in exiv2 ffmpeg mediainfo nproc; do
    if ! command -v "$cmd" &> /dev/null; then echo "Error: El comando '$cmd' no se encuentra."; exit 1; fi
done

if [ ! -d "$SOURCE_DIR" ]; then echo "Error: El directorio de origen '$SOURCE_DIR' no existe."; exit 1; fi

mkdir -p "$DEST_DIR" "$ORIGINALS_DIR"
set +e

# --- BLOQUEO DE CONCURRENCIA ---
LOCK_FILE="/tmp/organizer.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || { echo "Otra instancia del script ya se está ejecutando." >&2; exit 1; }

# --- CONFIGURACIÓN DE LOCK GLOBAL PARA MOVER ---
# Un único archivo de lock para serializar las operaciones de movimiento
MOVE_LOCK_FILE="/tmp/organizer_move.lock"

# --- CONFIGURACIÓN ---
# Paralelismo configurable
MAX_JOBS=${MAX_JOBS:-1}
NUM_CORES=$(nproc)
echo "INFO: Configuración de paralelismo: MAX_JOBS=$MAX_JOBS"
echo "INFO: Hilos por conversión (si aplica): $NUM_CORES"

declare -A album_year_map
declare -A mkdir_cache

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

# --- DEFINICIÓN DE FUNCIONES ---

get_file_date() {
    local file="$1"
    local date_str=""
    
    # 1. Intentar con exiv2 (DateTimeOriginal) - Más rápido
    date_str=$(exiv2 -g DateTimeOriginal -Pv "$file" 2>/dev/null | head -n1)
    if [[ "$date_str" =~ ^[0-9]{4}:[0-9]{2}:[0-9]{2} ]]; then
        # Usar parameter expansion en lugar de sed/cut
        echo "${date_str:0:4}-${date_str:5:2}-${date_str:8:2}"
        return
    fi

    # 2. Intentar con exiv2 (DateCreated - para algunos RAWs/XMP)
    date_str=$(exiv2 -g DateCreated -Pv "$file" 2>/dev/null | head -n1)
    if [[ "$date_str" =~ ^[0-9]{4}:[0-9]{2}:[0-9]{2} ]]; then
        echo "${date_str:0:4}-${date_str:5:2}-${date_str:8:2}"
        return
    fi

    # 3. Fallback a mediainfo (útil para videos si exiv2 falla)
    date_str=$(mediainfo --Output="General;%Encoded_Date%" "$file" 2>/dev/null)
    if [[ "$date_str" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
        echo "${date_str:0:10}"
        return
    fi

    # 4. Fallback al nombre del archivo
    local filename=$(basename "$file")
    local current_year=$(date +%Y)
    
    # Pattern 1: YYYY-MM-DD or YYYYMMDD
    if [[ "$filename" =~ ([0-9]{4})[-_]?([0-9]{2})[-_]?([0-9]{2}) ]]; then
        local year="${BASH_REMATCH[1]}"
        local month="${BASH_REMATCH[2]}"
        local day="${BASH_REMATCH[3]}"
        
        # Force base-10 interpretation by removing leading zeros
        year=$((10#$year))
        month=$((10#$month))
        day=$((10#$day))
        
        # Validate year (1900 to current year)
        if [[ "$year" -ge 1900 && "$year" -le "$current_year" ]]; then
            # Validate month (01-12)
            if [[ "$month" -ge 1 && "$month" -le 12 ]]; then
                # Validate day (01-31) - basic validation
                if [[ "$day" -ge 1 && "$day" -le 31 ]]; then
                    # Format with leading zeros
                    printf "%04d-%02d-%02d\n" "$year" "$month" "$day"
                    return
                fi
            fi
        fi
    fi
    
    # Pattern 2: DD-MM-YYYY or DDMMYYYY
    if [[ "$filename" =~ ([0-9]{2})[-_]?([0-9]{2})[-_]?([0-9]{4}) ]]; then
        local day="${BASH_REMATCH[1]}"
        local month="${BASH_REMATCH[2]}"
        local year="${BASH_REMATCH[3]}"
        
        # Force base-10 interpretation by removing leading zeros
        year=$((10#$year))
        month=$((10#$month))
        day=$((10#$day))
        
        # Validate year (1900 to current year)
        if [[ "$year" -ge 1900 && "$year" -le "$current_year" ]]; then
            # Validate month (01-12)
            if [[ "$month" -ge 1 && "$month" -le 12 ]]; then
                # Validate day (01-31) - basic validation
                if [[ "$day" -ge 1 && "$day" -le 31 ]]; then
                    # Format with leading zeros
                    printf "%04d-%02d-%02d\n" "$year" "$month" "$day"
                    return
                fi
            fi
        fi
    fi

    # 5. Último recurso: fecha de modificación del archivo
    date -r "$file" "+%Y-%m-%d"
}

# Función para determinar el año de un álbum escaneando los primeros archivos
get_album_year() {
    local dir="$1"
    
    # Usar cache si ya se calculó para este directorio
    if [[ -n "${album_year_map[$dir]}" ]]; then
        echo "${album_year_map[$dir]}"
        return
    fi
    
    # Escanear hasta 5 archivos para adivinar el año
    local files_checked=0
    while IFS= read -r f; do
        d=$(get_file_date "$f")
        # Usar parameter expansion en lugar de cut
        y="${d%%-*}"
        if [[ "$y" =~ ^[0-9]{4}$ ]]; then
            album_year_map[$dir]="$y"
            echo "$y"
            return
        fi
        ((files_checked++))
        if [ "$files_checked" -ge 5 ]; then break; fi
    done < <(find "$dir" -maxdepth 1 -type f)
    
    # Si no se encuentra nada, usar año actual como fallback seguro
    local current_year=$(date +%Y)
    album_year_map[$dir]="$current_year"
    echo "$current_year"
}

# Función para obtener un nombre de archivo único si ya existe
get_unique_filename() {
    local dir="$1"
    local filename="$2"
    local name="${filename%.*}"
    local ext="${filename##*.}"
    local new_name="$filename"
    local counter=1

    # Manejo correcto de archivos sin extensión
    if [[ "$name" == "$filename" ]]; then
        ext=""
    else
        ext=".$ext"
    fi

    while [ -e "$dir/$new_name" ]; do
        new_name="${name}_${counter}${ext}"
        ((counter++))
    done

    echo "$new_name"
}

# Función para mover archivos de forma inteligente (comprobando contenido)
smart_move() {
    local src="$1"
    local dest_dir="$2"
    local filename="$3"
    
    local dest_file="$dest_dir/$filename"
    
    # Calcular path relativo al destino para logging
    local rel_dest_path="${dest_dir#$DEST_DIR}"
    rel_dest_path="${rel_dest_path#/}"  # Quitar / inicial si existe
    
    # --- LOCKING START ---
    (
        if ! flock -w 60 -x 202; then
            echo "ERROR: Timeout esperando lock para $filename. Saltando."
            exit 1
        fi
        
        if [ -f "$dest_file" ]; then
            local size_src=$(stat -c %s "$src")
            local size_dest=$(stat -c %s "$dest_file")
            
            if [ "$size_src" -eq "$size_dest" ]; then
                echo "  ✓ $filename -> $rel_dest_path/ (idéntico, sobrescribiendo)"
                mv -f "$src" "$dest_file"
            else
                local new_filename=$(get_unique_filename "$dest_dir" "$filename")
                echo "  ✓ $filename -> $rel_dest_path/$new_filename (renombrado, ya existía diferente)"
                mv -n "$src" "$dest_dir/$new_filename"
            fi
        else
            echo "  ✓ $filename -> $rel_dest_path/ (nuevo)"
            mv -n "$src" "$dest_file"
        fi
    ) 202>"$MOVE_LOCK_FILE"
    # --- LOCKING END ---
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
    local TMP_DIR; TMP_DIR=$(mktemp -d); trap 'rm -rf "$TMP_DIR"' EXIT
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
        
        # Mover video convertido (usando smart_move por seguridad, aunque el nombre suele ser nuevo)
        local final_filename="${base_name_sanitized}_H264.mp4"
        smart_move "$output_file_temp" "$dest_path" "$final_filename"
        
        # Mover original a originales (usando smart_move para evitar duplicados innecesarios)
        local original_filename_raw=$(basename "$file")
        local original_filename_sanitized=${original_filename_raw// /_}
        smart_move "$file" "$originals_dir" "$original_filename_sanitized"
    else
        echo "ERROR: Falló la conversión de '$(basename "$file")'. El original se dejará en su sitio."
    fi
    trap - RETURN; rm -rf "$TMP_DIR"
    echo "FINALIZADA conversión de video (PID $$): $(basename "$file")"
}

process_file() {
    local remote_file="$1"
    
    if [ -z "$remote_file" ]; then return; fi
    
    # --- BUFFER LOCAL ---
    # Crear directorio temporal único para este proceso
    local TMP_WORK_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_WORK_DIR"' EXIT
    
    local filename=$(basename "$remote_file")
    local local_file="$TMP_WORK_DIR/$filename"
    
    # --- FILTRADO DE ARCHIVOS TEMPORALES ---
    case "$filename" in
        *.tacitpart|*.tmp|*.part)
            echo "OMITIENDO: Archivo temporal detectado '$filename'"
            return
            ;;
    esac

    # Copiar archivo remoto a local
    if ! cp --preserve=timestamps "$remote_file" "$local_file"; then
        echo "ERROR: Falló la descarga de '$remote_file'. Saltando."
        return
    fi
    
    # Usar el archivo LOCAL para todo el procesamiento
    local file="$local_file"
    
    # Optimización: usar bash 4.0+ lowercase en lugar de tr
    ext_lower="${filename##*.}"
    ext_lower="${ext_lower,,}"
    file_type=""
    case "$ext_lower" in
        jpg|jpeg|gif|png|heic|cr2|crw|nef|orf|raw|dng|arw) file_type="image" ;;
        mov|3gp|avi|mkv|mp4|mpg|mpeg|wmv|flv|webm|m4v|mts) file_type="video" ;;
        *) echo "OMITIENDO: Archivo no reconocido '$file'"; return ;;
    esac
    
    file_date=$(get_file_date "$file")
    if [ -z "$file_date" ]; then echo "ERROR: No se pudo determinar la fecha para '$file'. Omitiendo."; return; fi
    # Usar parameter expansion en lugar de cut
    year="${file_date%%-*}"
    month="${file_date:5:2}"
    file_dir=$(dirname "$remote_file")
    
    if [ "$SINGLE_ALBUM_MODE" -eq 1 ]; then
        # En modo álbum único, forzamos el destino al nombre del álbum sanitizado
        dest_path="$DEST_DIR/$ALBUM_NAME_SANITIZED"
    elif [ "$file_dir" == "$SOURCE_DIR" ]; then
        dest_path="$DEST_DIR/$year/$month"
    else
        album_name_raw=$(basename "$file_dir"); album_name_sanitized=${album_name_raw// /_}
        # Nota: En ejecución paralela, album_year_map no se comparte entre subshells.
        # Se recalcula cada vez, lo cual es aceptable según el plan.
        # Para get_album_year, seguimos usando el directorio remoto porque escanearlo localmente sería muy costoso (descargar todo el álbum).
        # Esto es un compromiso aceptable.
        album_year=$(get_album_year "$file_dir")
        if [ -z "$album_year" ]; then album_year=$year; fi # Fallback
        
        dest_path="$DEST_DIR/$album_year/$album_name_sanitized"
    fi
    
    # Optimización: mkdir con cache para evitar llamadas redundantes
    if [[ -z "${mkdir_cache[$dest_path]}" ]]; then
        mkdir -p "$dest_path"
        mkdir_cache[$dest_path]=1
    fi
    
    filename_raw=$(basename "$file"); filename_sanitized=${filename_raw// /_}

    if [ "$file_type" == "image" ]; then
        # Usar smart_move para imágenes (Mueve de LOCAL a REMOTO)
        if smart_move "$file" "$dest_path" "$filename_sanitized"; then
            # Si se movió correctamente al destino, borramos el original remoto
            rm "$remote_file"
        else
            echo "ERROR: Falló al mover '$filename' al destino."
        fi

    elif [ "$file_type" == "video" ]; then
        
        # 1. Comprobar si el archivo en origen YA es AV1 (suffix _AV1.mp4) -> mover directo a destino (NO a originales)
        if [[ "$filename_raw" == *_AV1.mp4 ]]; then
            echo "SALTANDO (AV1 ya convertido): $(basename "$file")"
            if smart_move "$file" "$dest_path" "$filename_sanitized"; then
                rm "$remote_file"
            fi
            return
        fi

        # 2. Comprobar si el archivo en origen YA es H264 (mirando el nombre original) -> mover directo a destino
        if [[ "$filename_raw" == *_H264.* ]]; then
            echo "SALTANDO (H264 ya convertido): $(basename "$file")"
            if smart_move "$file" "$dest_path" "$filename_sanitized"; then
                rm "$remote_file"
            fi
            return
        fi
        
        # 3. Comprobar si el archivo convertido H264 YA existe en el destino (nombre base)
        ext="${file##*.}"
        base_name_raw=$(basename "$file" ."$ext")
        base_name_sanitized=${base_name_raw// /_}
        potential_target_file="$dest_path/${base_name_sanitized}_H264.mp4"

        if [ -f "$potential_target_file" ]; then
            echo "SALTANDO (destino ya existe): El archivo '$potential_target_file' ya existe."
            
            local original_filename_sanitized=${filename_raw// /_}
            if smart_move "$file" "$ORIGINALS_DIR" "$original_filename_sanitized"; then
                rm "$remote_file"
            fi
            return
        fi

        # Ejecución SÍNCRONA dentro del job paralelo
        # process_video ahora trabaja con el archivo LOCAL
        # Pero process_video intenta mover el archivo original a ORIGINALS_DIR.
        # Necesitamos adaptar process_video o manejarlo aquí.
        # process_video toma: file, dest_path, originals_dir, num_threads
        # Modificaremos process_video para que NO mueva el original si es un archivo temporal, 
        # o simplemente dejamos que process_video mueva el local a originals_dir (remoto) y luego borramos el remoto original aquí.
        
        # El problema es que process_video hace 'smart_move "$file" "$originals_dir"'.
        # Si "$file" es local, lo moverá a remoto. Eso es correcto.
        # Si process_video tiene éxito, significa que el video convertido está en destino Y el original (local) está en originals_dir.
        # Entonces podemos borrar el remote_file.
        
        if process_video "$file" "$dest_path" "$ORIGINALS_DIR" "$NUM_CORES"; then
             rm "$remote_file"
        fi
    fi
}

export -f process_video get_file_date get_unique_filename smart_move get_album_year process_file
export SOURCE_DIR DEST_DIR ORIGINALS_DIR USE_GPU MAX_JOBS NUM_CORES MOVE_LOCK_FILE SINGLE_ALBUM_MODE ALBUM_NAME_SANITIZED
export -A album_year_map mkdir_cache

# --- PROCESAMIENTO PRINCIPAL ---
echo "Iniciando la organización de '$SOURCE_DIR'..."
echo "-------------------------------------------"

# Pre-escaneo de álbumes (opcional pero recomendado para consistencia)
# Se hará bajo demanda para no retardar el inicio.

# Array para rastrear PIDs de trabajos en segundo plano
declare -a job_pids=()

while IFS= read -r file; do
    # Control de trabajos paralelos
    while (( $(jobs -p | wc -l) >= MAX_JOBS )); do
        wait -n
    done
    
    process_file "$file" &
    job_pids+=($!)
done < <(find "$SOURCE_DIR" -type f \( \
    -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.gif" -o -iname "*.png" -o \
    -iname "*.heic" -o -iname "*.cr2" -o -iname "*.crw" -o -iname "*.nef" -o \
    -iname "*.orf" -o -iname "*.raw" -o -iname "*.dng" -o -iname "*.arw" -o \
    -iname "*.mov" -o -iname "*.3gp" -o -iname "*.avi" -o -iname "*.mkv" -o \
    -iname "*.mp4" -o -iname "*.mpg" -o -iname "*.mpeg" -o -iname "*.wmv" -o \
    -iname "*.flv" -o -iname "*.webm" -o -iname "*.m4v" -o -iname "*.mts" \
\))

# --- FINALIZACIÓN ---
echo "-------------------------------------------"
echo "Todos los archivos han sido puestos en cola. Esperando a que terminen las conversiones restantes..."
echo "Esperando ${#job_pids[@]} trabajos..."

# Esperar explícitamente cada trabajo rastreado
for pid in "${job_pids[@]}"; do
    wait "$pid" 2>/dev/null || true
done

echo "Todas las tareas han finalizado."
echo "Proceso de organización completado."
echo "=== FIN DEL PROCESO: $(date) ==="

# Limpieza final de locks (aunque flock debería manejarlos, es bueno borrar el archivo)
rm -f "$MOVE_LOCK_FILE"
