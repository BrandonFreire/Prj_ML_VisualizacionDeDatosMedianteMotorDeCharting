#!/usr/bin/env bash
# Pipeline completo: extrae features → entrena → evalúa → predice
# Uso: bash run_all.sh [CSV_TRAIN] [CSV_TEST]
#   CSV_TRAIN: archivo de datos de entrenamiento (default: ../2026_03_mayo.csv)
#   CSV_TEST:  archivo de datos de prueba       (default: ../2026_03_julio.csv)

set -euo pipefail
cd "$(dirname "$0")"

TRAIN_DATA="${1:-../2026_03_mayo.csv}"
TEST_DATA="${2:-../2026_03_julio.csv}"
TRAIN_FEATURES="features_train.csv"
TEST_FEATURES="features_test.csv"

echo "=========================================="
echo "  PIPELINE ML - PREDICCIÓN DE FANTASMAS"
echo "=========================================="
echo "  Datos de entrenamiento: $TRAIN_DATA"
echo "  Datos de testeo:        $TEST_DATA"
echo ""

# ------------------------------------------
# PASO 1: Extracción de features (Perl)
# ------------------------------------------
echo "[1/4] Extrayendo features de entrenamiento..."
if [ ! -f "$TRAIN_DATA" ]; then
    echo "ERROR: No se encontró $TRAIN_DATA"
    exit 1
fi
perl extract_features.pl "$TRAIN_DATA" "$TRAIN_FEATURES"
echo "  -> $TRAIN_FEATURES"

echo "[2/4] Extrayendo features de testeo..."
if [ ! -f "$TEST_DATA" ]; then
    echo "ERROR: No se encontró $TEST_DATA"
    exit 1
fi
perl extract_features.pl "$TEST_DATA" "$TEST_FEATURES"
echo "  -> $TEST_FEATURES"

# ------------------------------------------
# PASO 2: Entrenamiento (Python)
# ------------------------------------------
echo ""
echo "[3/4] Entrenando modelo..."
python3 train.py "$TRAIN_FEATURES"

# ------------------------------------------
# PASO 3: Evaluación en datos de testeo
# ------------------------------------------
echo ""
echo "[4/4] Evaluando en datos de testeo (julio)..."
python3 evaluate.py "$TEST_FEATURES"

# ------------------------------------------
# PASO 4 (opcional): Demo de predicción
# ------------------------------------------
echo ""
echo "=========================================="
echo "  Demo: últimas 5 predicciones en testeo"
echo "=========================================="
python3 predict.py "$TEST_FEATURES" --last 5

echo ""
echo "Pipeline completo. Archivos generados:"
echo "  model_fantasmas.joblib    <- modelo entrenado"
echo "  scaler_params.joblib      <- normalizador"
echo "  norm_params.json          <- parámetros de features"
echo "  $TRAIN_FEATURES           <- features de entrenamiento"
echo "  $TEST_FEATURES            <- features de testeo"
echo "  ${TEST_FEATURES%.csv}_predictions.csv <- predicciones"
