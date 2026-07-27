#!/usr/bin/env python3
"""
Evaluación del modelo predictivo en datos de testeo (Julio)

Uso:
    python3 evaluate.py features_test.csv
"""

import sys
import pandas as pd
import numpy as np
from sklearn.metrics import mean_absolute_error, r2_score, mean_squared_error
import joblib
import json

# ============================================================
_DIR        = os.path.dirname(os.path.abspath(__file__))
INPUT_CSV   = sys.argv[1] if len(sys.argv) > 1 else os.path.join(_DIR, "features_test.csv")
MODEL_FILE  = os.path.join(_DIR, "model_fantasmas.joblib")
SCALER_FILE = os.path.join(_DIR, "scaler_params.joblib")
PARAMS_FILE = os.path.join(_DIR, "norm_params.json")

TARGETS = ['traces_3m', 'traces_5m', 'traces_10m', 'traces_15m']
META_COLS = ['datetime', 'epoch', 'ghost_index']
# ============================================================

print(f"Cargando modelo desde {MODEL_FILE}...")
model  = joblib.load(MODEL_FILE)
scaler = joblib.load(SCALER_FILE)

with open(PARAMS_FILE) as f:
    params = json.load(f)
FEATURES = params['features']

print(f"Cargando datos de testeo desde {INPUT_CSV}...")
df = pd.read_csv(INPUT_CSV)
print(f"  {len(df)} registros")

df = df.dropna(subset=FEATURES + TARGETS)
for t in TARGETS:
    df = df[df[t] >= 0]
print(f"  {len(df)} registros válidos")

if len(df) == 0:
    print("ERROR: sin datos válidos para evaluar.")
    sys.exit(1)

X = df[FEATURES].values
y = df[TARGETS].values

X_scaled = scaler.transform(X)
y_pred   = model.predict(X_scaled)
y_pred_i = np.round(y_pred).astype(int).clip(0)

# ============================================================
# REPORTE DE EVALUACIÓN
# ============================================================
print("\n" + "="*60)
print("EVALUACIÓN EN DATOS DE TESTEO (JULIO)")
print("="*60)
print(f"{'Ventana':<12} {'MAE':>8} {'RMSE':>8} {'R²':>8} {'Acc±0':>8} {'Acc±1':>8}")
print("-"*60)

for i, t in enumerate(TARGETS):
    mae  = mean_absolute_error(y[:, i], y_pred[:, i])
    rmse = np.sqrt(mean_squared_error(y[:, i], y_pred[:, i]))
    r2   = r2_score(y[:, i], y_pred[:, i])
    acc0 = np.mean(y[:, i].astype(int) == y_pred_i[:, i]) * 100
    acc1 = np.mean(np.abs(y[:, i] - y_pred_i[:, i]) <= 1) * 100
    print(f"{t:<12} {mae:>8.3f} {rmse:>8.3f} {r2:>8.3f} {acc0:>7.1f}% {acc1:>7.1f}%")

print("="*60)

# Ejemplos de predicciones
print("\nEJEMPLOS DE PREDICCIONES (primeros 10 fantasmas del test):")
print(f"{'#':<4} {'Fecha':<22} {'Tipo':<6} " +
      " ".join(f"{'R'+t[7:]+'|P'+t[7:]:<10}" for t in TARGETS))
print("-"*90)

meta_available = all(c in df.columns for c in ['datetime', 'ghost_type'])
for idx in range(min(10, len(df))):
    row = df.iloc[idx]
    fecha = str(row['datetime'])[:19] if 'datetime' in df.columns else str(idx)
    tipo  = "ALTO" if row.get('ghost_type', 0) == 1 else "BAJO"
    reales = [int(row[t]) for t in TARGETS]
    preds  = [int(y_pred_i[idx, i]) for i in range(len(TARGETS))]
    cols   = " ".join(f"{r}|{p:<8}" for r,p in zip(reales, preds))
    print(f"{idx:<4} {fecha:<22} {tipo:<6} {cols}")

# Comparación por tipo de fantasma
print("\nComparación por tipo de fantasma:")
for tipo in [0, 1]:
    mask = df['ghost_type'] == tipo if 'ghost_type' in df.columns else np.ones(len(df), bool)
    if not mask.any():
        continue
    label = "ALTO" if tipo == 1 else "BAJO"
    print(f"\n  Fantasma {label} ({mask.sum()} casos):")
    for i, t in enumerate(TARGETS):
        mae = mean_absolute_error(y[mask, i], y_pred[mask, i])
        print(f"    {t}: MAE={mae:.3f}")
