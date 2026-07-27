#!/usr/bin/env python3
"""
Entrenamiento del modelo predictivo de Fantasmas
Predice cuántos rastros deja el fantasma en ventanas de 3, 5, 10 y 15 minutos

Uso:
    python3 train.py features_train.csv
"""

import sys
import pandas as pd
import numpy as np
from sklearn.ensemble import RandomForestRegressor
from sklearn.multioutput import MultiOutputRegressor
from sklearn.preprocessing import StandardScaler
from sklearn.model_selection import train_test_split
from sklearn.metrics import mean_absolute_error, r2_score, mean_squared_error
import joblib
import json
import os

# ============================================================
# CONFIGURACIÓN
# ============================================================
_DIR        = os.path.dirname(os.path.abspath(__file__))
INPUT_CSV   = sys.argv[1] if len(sys.argv) > 1 else os.path.join(_DIR, "features_train.csv")
MODEL_FILE  = os.path.join(_DIR, "model_fantasmas.joblib")
SCALER_FILE = os.path.join(_DIR, "scaler_params.joblib")
PARAMS_FILE = os.path.join(_DIR, "norm_params.json")

TARGETS = ['traces_3m', 'traces_5m', 'traces_10m', 'traces_15m']

# Columnas de metadata (NO entran al modelo)
META_COLS = ['datetime', 'epoch', 'ghost_index']

FEATURES = [
    'ghost_type',
    'dist_ghost_pips',
    'atr',
    'body_atr', 'upper_wick_atr', 'lower_wick_atr',
    'rsi', 'close_ret1_atr', 'close_ret5_atr', 'close_ret15_atr',
    'vol', 'vol_ema9', 'vol_ratio',
    'dist_sh5_above', 'dist_sl5_below',
    'n_sh5_near', 'n_sl5_near',
    'dist_sh10_above', 'dist_sl10_below',
    'dist_bsl_above', 'dist_ssl_below',
    'dist_bos_above', 'dist_bos_below',
    'dist_fvg_above', 'dist_fvg_below',
    'dist_ob_above', 'dist_ob_below',
    'dist_fib_pips',
    'zz_high_dist_pips', 'zz_low_dist_pips',
]

# ============================================================
# CARGA Y LIMPIEZA
# ============================================================
print(f"Cargando {INPUT_CSV}...")
df = pd.read_csv(INPUT_CSV)
print(f"  {len(df)} registros, {len(df.columns)} columnas")

# 999 = "sin nivel cercano detectado" — es información válida para el modelo,
# no un valor faltante. Solo eliminamos filas con NaN reales (primeras barras
# donde ATR/RSI aún no convergen) y filas con targets negativos (sin barras futuras).
df = df.dropna(subset=FEATURES + TARGETS)
for t in TARGETS:
    df = df[df[t] >= 0]
print(f"  {len(df)} registros después de limpieza")

if len(df) < 50:
    print("ERROR: muy pocos registros para entrenar. Verifique el CSV de entrada.")
    sys.exit(1)

X = df[FEATURES].values
y = df[TARGETS].values

# ============================================================
# NORMALIZACIÓN
# ============================================================
print("Normalizando features...")
scaler = StandardScaler()
X_scaled = scaler.fit_transform(X)

# Guardar parámetros de normalización (para reproducibilidad)
norm_params = {
    "features": FEATURES,
    "mean": scaler.mean_.tolist(),
    "scale": scaler.scale_.tolist(),
    "targets": TARGETS
}
with open(PARAMS_FILE, 'w') as f:
    json.dump(norm_params, f, indent=2)

# ============================================================
# SPLIT TRAIN / VALIDACIÓN (80/20, sin shuffle para respetar tiempo)
# ============================================================
split = int(len(X_scaled) * 0.8)
X_train, X_val = X_scaled[:split], X_scaled[split:]
y_train, y_val = y[:split], y[split:]
print(f"  Train: {len(X_train)} | Val: {len(X_val)}")

# ============================================================
# MODELO — Random Forest Multi-salida
# Cada target (3m, 5m, 10m, 15m) tiene su propio árbol
# ============================================================
print("\nEntrenando Random Forest (MultiOutput)...")
rf = RandomForestRegressor(
    n_estimators=200,
    max_depth=12,
    min_samples_leaf=3,
    random_state=42,
    n_jobs=-1,
)
model = MultiOutputRegressor(rf)
model.fit(X_train, y_train)

# ============================================================
# EVALUACIÓN EN VALIDACIÓN
# ============================================================
y_pred = model.predict(X_val)
y_pred_int = np.round(y_pred).astype(int).clip(0)

print("\n" + "="*55)
print("RESULTADOS EN VALIDACIÓN")
print("="*55)
print(f"{'Ventana':<12} {'MAE':>8} {'RMSE':>8} {'R²':>8} {'Exactitud±1':>12}")
print("-"*55)

for i, target in enumerate(TARGETS):
    mae  = mean_absolute_error(y_val[:, i], y_pred[:, i])
    rmse = np.sqrt(mean_squared_error(y_val[:, i], y_pred[:, i]))
    r2   = r2_score(y_val[:, i], y_pred[:, i])
    # Exactitud: predicción dentro de ±1 del valor real
    acc1 = np.mean(np.abs(y_val[:, i] - y_pred_int[:, i]) <= 1) * 100
    print(f"{target:<12} {mae:>8.3f} {rmse:>8.3f} {r2:>8.3f} {acc1:>11.1f}%")

print("="*55)

# Distribución de los targets en validación
print("\nDistribución de rastros reales (validación):")
for i, t in enumerate(TARGETS):
    vals, counts = np.unique(y_val[:, i].astype(int), return_counts=True)
    dist = " | ".join(f"{v}:{c}" for v,c in zip(vals, counts))
    print(f"  {t}: {dist}")

# Importancia de features (del primer estimador como referencia)
if hasattr(model.estimators_[0], 'feature_importances_'):
    imp = model.estimators_[0].feature_importances_
    top5 = sorted(zip(FEATURES, imp), key=lambda x: -x[1])[:5]
    print("\nTop-5 features más importantes (para traces_3m):")
    for name, score in top5:
        print(f"  {name:<30} {score:.4f}")

# ============================================================
# GUARDAR MODELO Y SCALER
# ============================================================
joblib.dump(model,  MODEL_FILE)
joblib.dump(scaler, SCALER_FILE)
print(f"\nModelo guardado en:  {MODEL_FILE}")
print(f"Scaler guardado en:  {SCALER_FILE}")
print(f"Parámetros en:       {PARAMS_FILE}")
