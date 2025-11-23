#!/bin/bash
# Script de validación automática para organizar_fotos.sh

# Colores
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass=0
fail=0

log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((pass++)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; ((fail++)); }

# 1. Mock de exiv2 si no existe (para que el test funcione en entornos sin la herramienta)
if ! command -v exiv2 &> /dev/null; then
    echo "⚠️  exiv2 no encontrado. Creando mock..."
    cat << 'EOF' > exiv2
#!/bin/bash
# Mock simple que devuelve fechas basadas en el nombre del archivo o una por defecto
filename="$3"
if [[ "$filename" == *"2023"* ]]; then
  echo "2023:05:15 10:00:00"
elif [[ "$filename" == *"2024"* ]]; then
  echo "2024:02:20 11:00:00"
elif [[ "$filename" == *"video_duplicado"* ]]; then
  echo "2022:12:25 18:00:00"
else
  # Fallback genérico
  echo "2023:01:01 12:00:00"
fi
EOF
    chmod +x exiv2
    export PATH=$PWD:$PATH
fi

# 2. Crear entorno
echo "--- Creando entorno de prueba ---"
./crear_entorno_test.sh > /dev/null
if [ $? -eq 0 ]; then log_pass "Entorno creado"; else log_fail "Fallo al crear entorno"; exit 1; fi

TEST_ROOT="entorno_de_prueba"
SOURCE="$TEST_ROOT/origen"
DEST="$TEST_ROOT/destino"
ORIGINALS="$TEST_ROOT/videos_originales"

# 3. Ejecutar script
echo "--- Ejecutando organizar_fotos.sh ---"
export MAX_JOBS=2
./organizar_fotos.sh "$SOURCE" "$DEST" "$ORIGINALS"

# 4. Validaciones

# Caso 1: Video raíz convertido (H264)
if [ -f "$DEST/2024/02/video_raiz_H264.mp4" ]; then
    log_pass "Video raíz convertido correctamente (H264)"
else
    log_fail "Falta video raíz convertido ($DEST/2024/02/video_raiz_H264.mp4)"
fi

# Caso 2: Video ya procesado (movido sin reconvertir)
if [ -f "$DEST/2023/Album_Viaje_a_la_Playa/video_ya_procesado_H264.mp4" ]; then
    log_pass "Video pre-procesado movido correctamente"
else
    log_fail "Falta video pre-procesado"
fi

# Caso 3: Video duplicado (destino existe -> mover original a originales)
if [ -f "$ORIGINALS/video_duplicado.mov" ]; then
    log_pass "Video duplicado movido a originales"
else
    log_fail "Video duplicado NO está en originales"
fi

# Caso 4: Renombrado de duplicados (foto_con_exif.jpg -> foto_con_exif_1.jpg)
# Nota: crear_entorno_test.sh pone una foto en 2023/05 llamada foto_con_exif.jpg
# La foto de origen tiene fecha 2023:05:15, así que irá a 2023/05.
if [ -f "$DEST/2023/05/foto_con_exif_1.jpg" ]; then
    log_pass "Duplicado de imagen renombrado correctamente (_1)"
else
    log_fail "Falta imagen renombrada (foto_con_exif_1.jpg)"
fi

# Caso 5: Limpieza de origen
if [ -z "$(ls -A "$SOURCE")" ]; then
    log_pass "Directorio de origen está vacío (Limpieza OK)"
else
    log_fail "Directorio de origen NO está vacío"
    ls -R "$SOURCE"
fi

# Caso 6: Log file
if ls organizer_*.log 1> /dev/null 2>&1; then
    log_pass "Archivo de log creado"
else
    log_fail "No se creó archivo de log"
fi

echo "---------------------------------------"
echo "Resultados: $pass PASS / $fail FAIL"
if [ $fail -eq 0 ]; then
    echo -e "${GREEN}✅ TEST COMPLETADO EXITOSAMENTE${NC}"
    # Cleanup
    rm -rf "$TEST_ROOT" exiv2 organizer_*.log
    exit 0
else
    echo -e "${RED}❌ TEST FALLIDO${NC}"
    exit 1
fi
