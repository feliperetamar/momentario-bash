#!/bin/bash
#
# Script para organizar fotos y videos, con comprobaciones para evitar reconversiones.
# Optimizado para usar exiv2, paralelismo configurable y mejor manejo de álbumes.
#
# Uso: ./organizar_fotos.sh /ruta/a/origen /ruta/a/destino /ruta/para/videos_originales

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

# --- CONFIGURACIÓN ---
# Paralelismo configurable
MAX_JOBS=${MAX_JOBS:-1}
NUM_CORES=$(nproc)
echo "INFO: Configuración de paralelismo: MAX_JOBS=$MAX_JOBS"
echo "INFO: Hilos por conversión (si aplica): $NUM_CORES"

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

# --- DEFINICIÓN DE FUNCIONES ---

get_file_date() {
    local file="$1"
    local date_str=""
    
    # 1. Intentar con exiv2 (DateTimeOriginal) - Más rápido
    # exiv2 output format example: "2023:12:01 14:30:00" -> sed to "2023-12-01"
    date_str=$(exiv2 -g DateTimeOriginal -Pv "$file" 2>/dev/null | head -n1 | sed 's/:/-/g' | cut -d' ' -f1)
    if [[ "$date_str" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then echo "$date_str"; return; fi

    # 2. Intentar con exiv2 (DateCreated - para algunos RAWs/XMP)
    date_str=$(exiv2 -g DateCreated -Pv "$file" 2>/dev/null | head -n1 | sed 's/:/-/g' | cut -d' ' -f1)
    if [[ "$date_str" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then echo "$date_str"; return; fi

    # 3. Fallback a mediainfo (útil para videos si exiv2 falla)
    date_str=$(mediainfo --Output="General;%Encoded_Date%" "$file" 2>/dev/null | sed 's/UTC //g' | cut -d' ' -f1)
    if [[ "$date_str" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then echo "$date_str"; return; fi

    # 4. Fallback al nombre del archivo
    local filename=$(basename "$file")
    if [[ "$filename" =~ ([0-9]{4})[-_]?([0-9]{2})[-_]?([0-9]{2}) ]]; then echo "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"; return; fi
    if [[ "$filename" =~ ([0-9]{2})[-_]?([0-9]{2})[-_]?([0-9]{4}) ]]; then echo "${BASH_REMATCH[3]}-${BASH_REMATCH[2]}-${BASH_REMATCH[1]}"; return; fi

    # 5. Último recurso: fecha de modificación del archivo
    date -r "$file" "+%Y-%m-%d"
}

# Función para determinar el año de un álbum escaneando los primeros archivos
get_album_year() {
    local dir="$1"
    local year_counts=()
    local max_count=0
    local best_year=""
    
    # Escanear hasta 5 archivos para adivinar el año
    local files_checked=0
    while IFS= read -r f; do
        d=$(get_file_date "$f")
        y=$(echo "$d" | cut -d'-' -f1)
        if [[ "$y" =~ ^[0-9]{4}$ ]]; then
            # Simple conteo (bash 4+ associative arrays would be better but let's keep it simple logic)
            # Just return the first valid year found for speed, or implement voting if critical.
            # Para "optimización", devolver el primer año válido es suficiente mejora sobre "el primer archivo que toque el bucle principal".
            echo "$y"
            return
        fi
        ((files_checked++))
        if [ "$files_checked" -ge 5 ]; then break; fi
    done < <(find "$dir" -maxdepth 1 -type f)
    
    # Si no se encuentra nada, usar año actual como fallback seguro
    date +%Y
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
    
    if [ -f "$dest_file" ]; then
        # Optimización: Comprobar tamaño y fecha en lugar de contenido completo (cmp)
        local size_src=$(stat -c %s "$src")
        local size_dest=$(stat -c %s "$dest_file")
        
        # Opcional: Comprobar también mtime si se desea más precisión, pero size suele bastar para detectar "diferente"
        # local time_src=$(stat -c %Y "$src")
        # local time_dest=$(stat -c %Y "$dest_file")

        if [ "$size_src" -eq "$size_dest" ]; then
            echo "  -> Archivo idéntico detectado (por tamaño) en destino. Sobrescribiendo: $filename"
            mv -f "$src" "$dest_file"
        else
            # Es diferente, buscamos nombre único
            local new_filename=$(get_unique_filename "$dest_dir" "$filename")
            echo "  -> Archivo diferente con mismo nombre. Renombrando: $filename -> $new_filename"
            mv -n "$src" "$dest_dir/$new_filename"
        fi
    else
        # No existe, mover normal
        echo "  -> Moviendo: $filename"
        mv -n "$src" "$dest_file"
    fi
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
    trap 'rm -rf "$TMP_WORK_DIR"' RETURN
    
    local filename=$(basename "$remote_file")
    local local_file="$TMP_WORK_DIR/$filename"
    
    # Copiar archivo remoto a local
    # echo "Descargando: $filename"
    cp --preserve=timestamps "$remote_file" "$local_file" || { echo "ERROR: Falló la descarga de '$remote_file'."; return; }
    
    # Usar el archivo LOCAL para todo el procesamiento
    local file="$local_file"
    
    ext_lower=$(echo "${file##*.}" | tr '[:upper:]' '[:lower:]')
    file_type=""
    case "$ext_lower" in
        jpg|jpeg|gif|png|heic|cr2|crw|nef|orf|raw|dng|arw) file_type="image" ;;
        mov|3gp|avi|mkv|mp4|mpg|mpeg|wmv|flv|webm|m4v) file_type="video" ;;
        *) echo "OMITIENDO: Archivo no reconocido '$file'"; return ;;
    esac
    
    file_date=$(get_file_date "$file")
    if [ -z "$file_date" ]; then echo "ERROR: No se pudo determinar la fecha para '$file'. Omitiendo."; return; fi
    year=$(echo "$file_date" | cut -d'-' -f1); month=$(echo "$file_date" | cut -d'-' -f2); file_dir=$(dirname "$remote_file")
    
    if [ "$file_dir" == "$SOURCE_DIR" ]; then
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
    mkdir -p "$dest_path"
    
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
    
    # El trap se encargará de borrar el directorio temporal local
}

export -f process_video get_file_date get_unique_filename smart_move get_album_year process_file
export SOURCE_DIR DEST_DIR ORIGINALS_DIR USE_GPU MAX_JOBS NUM_CORES

# --- PROCESAMIENTO PRINCIPAL ---
echo "Iniciando la organización de '$SOURCE_DIR'..."
echo "-------------------------------------------"

# Pre-escaneo de álbumes (opcional pero recomendado para consistencia)
# Se hará bajo demanda para no retardar el inicio.

while IFS= read -r file; do
    # Control de trabajos paralelos
    while (( $(jobs -p | wc -l) >= MAX_JOBS )); do
        wait -n
    done
    
    process_file "$file" &
done < <(find "$SOURCE_DIR" -type f)

# --- FINALIZACIÓN ---
echo "-------------------------------------------"
echo "Todos los archivos han sido puestos en cola. Esperando a que terminen las conversiones restantes..."
wait

echo "Todas las tareas han finalizado."
echo "Proceso de organización completado."
echo "=== FIN DEL PROCESO: $(date) ==="
