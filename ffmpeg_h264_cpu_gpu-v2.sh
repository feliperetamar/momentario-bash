#!/bin/bash

# Configuración de extensiones
EXTENSIONS="mp4 mov mkv avi"

if [ -z "$1" ]; then
    echo "❌ Error: Indica la carpeta."
    exit 1
fi

TARGET_DIR="$1"
cd "$TARGET_DIR" || exit

echo "======================================================="
echo "🧪 TEST V2: CPU vs GPU (Optimizado) vs HEVC"
echo "======================================================="

for ext in $EXTENSIONS; do
    find . -maxdepth 1 -type f -iname "*.$ext" | while read -r file; do
        
        # Evitar procesar los generados
        if [[ "$file" == *"_CPU_"* ]] || [[ "$file" == *"_GPU_"* ]]; then
            continue
        fi

        filename=$(basename -- "$file")
        base="${filename%.*}"

        echo ""
        echo "-------------------------------------------------------"
        echo "📹 Video: $filename"
        orig_size=$(du -h "$filename" | cut -f1)
        
        # 1. CPU (Referencia)
        out_cpu="${base}_CPU_CRF24.mp4"
        echo "⚙️  [1/3] CPU (x264, CRF 24)..."
        start_cpu=$(date +%s)
        ffmpeg -y -v error -i "$file" -vf "scale=-2:1080" -c:v libx264 -crf 24 -preset veryfast -c:a aac -b:a 128k -movflags +faststart "$out_cpu"
        runtime_cpu=$(( $(date +%s) - start_cpu ))
        size_cpu=$(du -h "$out_cpu" | cut -f1)

        # 2. GPU H.264 (Optimizado QP 28)
        out_gpu_h264="${base}_GPU_H264_QP28.mp4"
        echo "⚡ [2/3] GPU H.264 (VAAPI, QP 28)..."
        start_gpu1=$(date +%s)
        ffmpeg -y -v error -vaapi_device /dev/dri/renderD128 -i "$file" \
            -vf "format=nv12,hwupload,scale_vaapi=w=-2:h=1080" \
            -c:v h264_vaapi -qp 28 \
            -c:a aac -b:a 128k -movflags +faststart "$out_gpu_h264"
        runtime_gpu1=$(( $(date +%s) - start_gpu1 ))
        size_gpu1=$(du -h "$out_gpu_h264" | cut -f1)

        # 3. GPU HEVC (H.265 - Máxima compresión)
        out_gpu_hevc="${base}_GPU_HEVC_QP28.mp4"
        echo "🚀 [3/3] GPU HEVC (H.265, QP 28)..."
        start_gpu2=$(date +%s)
        ffmpeg -y -v error -vaapi_device /dev/dri/renderD128 -i "$file" \
            -vf "format=nv12,hwupload,scale_vaapi=w=-2:h=1080" \
            -c:v hevc_vaapi -qp 28 \
            -c:a aac -b:a 128k -movflags +faststart "$out_gpu_hevc"
        
        # Si HEVC falla (por drivers), marcamos error
        if [ $? -ne 0 ]; then
            size_gpu2="ERROR"
            runtime_gpu2="0"
        else
            runtime_gpu2=$(( $(date +%s) - start_gpu2 ))
            size_gpu2=$(du -h "$out_gpu_hevc" | cut -f1)
        fi

        echo ""
        echo "📊 RESULTADOS: $filename"
        printf "| %-18s | %-10s | %-10s |\n" "MÉTODO" "TIEMPO" "TAMAÑO"
        echo "|--------------------|------------|------------|"
        printf "| %-18s | %-10s | %-10s |\n" "ORIGINAL" "---" "$orig_size"
        printf "| %-18s | %-10s | %-10s |\n" "CPU (x264 CRF24)" "${runtime_cpu}s" "$size_cpu"
        printf "| %-18s | %-10s | %-10s |\n" "GPU (H264 QP28)" "${runtime_gpu1}s" "$size_gpu1"
        printf "| %-18s | %-10s | %-10s |\n" "GPU (HEVC QP28)" "${runtime_gpu2}s" "$size_gpu2"
        echo "-------------------------------------------------------"

    done
done
