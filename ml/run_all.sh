#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

TRAIN_DATA="${1:-../2026_Abril-Junio.csv}"
TEST_DATA="${2:-../2026_07_24.csv}"
TRAIN_FEATURES="features_train.csv"
TEST_FEATURES="features_test.csv"

for source in "$TRAIN_DATA" "$TEST_DATA"; do
    if [[ ! -f "$source" ]]; then
        echo "ERROR: no se encontro $source" >&2
        exit 1
    fi
done

echo "============================================================"
echo " PIPELINE LSTM — RASTROS DE GHOSTS_IN_SWINGS"
echo " Train: abril-junio | Test externo: 1-24 julio"
echo "============================================================"

echo "[1/5] Extraccion causal de entrenamiento..."
perl extract_features.pl "$TRAIN_DATA" "$TRAIN_FEATURES"

echo "[2/5] Extraccion causal de test..."
perl extract_features.pl "$TEST_DATA" "$TEST_FEATURES"

echo "[3/5] Entrenamiento y persistencia LSTM..."
python3 train.py "$TRAIN_FEATURES" --enforce-project-range

echo "[4/5] Evaluacion con modelo y scaler recargados..."
python3 evaluate.py "$TEST_FEATURES" --enforce-project-range

echo "[5/5] Demostracion de las ultimas 10 predicciones..."
python3 predict.py "$TEST_FEATURES" --last 10

echo
echo "Pipeline completado:"
echo "  model_fantasmas_lstm.npz       pesos LSTM finales"
echo "  scaler_params_lstm.npz         imputacion/escalado de abril-junio"
echo "  model_config_lstm.json         esquema y arquitectura"
echo "  training_report_lstm.json      seleccion temporal y entrenamiento"
echo "  test_metrics_lstm.json         evaluacion externa de julio"
