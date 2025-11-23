#!/bin/bash
# Test específico para validar que NO se borra el origen si falla el destino

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

TEST_ROOT="test_seguridad"
SOURCE="$TEST_ROOT/origen"
DEST="$TEST_ROOT/destino"
ORIGINALS="$TEST_ROOT/originales"

# Limpieza
rm -rf "$TEST_ROOT"
mkdir -p "$SOURCE" "$DEST" "$ORIGINALS"

# Crear archivo de prueba
echo "datos" > "$SOURCE/archivo_importante.jpg"
# Simulamos fecha para que no falle get_file_date (usando nombre o touch si el script usa fallback)
# El script usa fallback a fecha de modificación, así que touch es suficiente.
touch -d "2023-01-01" "$SOURCE/archivo_importante.jpg"

# Hacemos el destino de solo lectura para provocar fallo en 'mv' (smart_move)
# Nota: smart_move intenta crear directorios con mkdir -p. 
# Si el directorio año/mes no existe, intentará crearlo.
# Vamos a crear el directorio destino final y quitarle permisos de escritura.
mkdir -p "$DEST/2023/01"
chmod a-w "$DEST/2023/01"

echo "--- Ejecutando script con destino de solo lectura ---"
# Ejecutamos el script
# Redirigimos stderr para no ensuciar, pero podríamos greparlo
./organizar_fotos.sh "$SOURCE" "$DEST" "$ORIGINALS"

echo "--- Verificando resultados ---"

# 1. El archivo NO debe estar en destino (porque falló la escritura)
if [ -f "$DEST/2023/01/archivo_importante.jpg" ]; then
    echo -e "${RED}[FAIL] El archivo apareció en destino (no debería haber podido escribirse)${NC}"
else
    echo -e "${GREEN}[PASS] El archivo no se pudo escribir en destino (comportamiento esperado)${NC}"
fi

# 2. El archivo DEBE seguir en origen (porque falló el movimiento)
if [ -f "$SOURCE/archivo_importante.jpg" ]; then
    echo -e "${GREEN}[PASS] El archivo original SIGUE en origen (Protección de borrado OK)${NC}"
else
    echo -e "${RED}[FAIL] ¡El archivo original FUE BORRADO a pesar del error!${NC}"
    exit 1
fi

# Cleanup
chmod u+w "$DEST/2023/01"
rm -rf "$TEST_ROOT"
exit 0
