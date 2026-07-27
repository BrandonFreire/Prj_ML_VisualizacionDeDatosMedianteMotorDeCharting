#!/usr/bin/env python3
"""
Demo de predicción — carga el modelo entrenado y predice sobre un CSV de features.

Uso:
    python3 predict.py features_test.csv          # predice todos
    python3 predict.py features_test.csv 5        # muestra los primeros N
    python3 predict.py features_test.csv --last 3 # muestra los últimos N

Salida:
    Tabla con fecha, tipo de fantasma, predicciones y (si están disponibles) los
    valores reales para comparar.
"""

import sys
import os
import pandas as pd
import numpy as np
import joblib
import json

# ============================================================
_DIR        = os.path.dirname(os.path.abspath(__file__))
MODEL_FILE  = os.path.join(_DIR, "model_fantasmas.joblib")
SCALER_FILE = os.path.join(_DIR, "scaler_params.joblib")
PARAMS_FILE = os.path.join(_DIR, "norm_params.json")
TARGETS     = ['traces_3m', 'traces_5m', 'traces_10m', 'traces_15m']
# ============================================================

def load_model():
    if not os.path.exists(MODEL_FILE):
        print(f"ERROR: No se encontró el modelo '{MODEL_FILE}'.")
        print("  Ejecute primero:  python3 train.py features_train.csv")
        sys.exit(1)
    model  = joblib.load(MODEL_FILE)
    scaler = joblib.load(SCALER_FILE)
    with open(PARAMS_FILE) as f:
        params = json.load(f)
    return model, scaler, params['features']

def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(0)

    input_csv = args[0]
    n_show = None
    show_last = False

    i = 1
    while i < len(args):
        if args[i] == '--last' and i + 1 < len(args):
            show_last = True
            n_show = int(args[i + 1])
            i += 2
        elif args[i].lstrip('-').isdigit():
            n_show = int(args[i])
            i += 1
        else:
            i += 1

    if not os.path.exists(input_csv):
        print(f"ERROR: No se encontró el archivo '{input_csv}'")
        sys.exit(1)

    print(f"Cargando modelo...")
    model, scaler, features = load_model()

    print(f"Cargando {input_csv}...")
    df = pd.read_csv(input_csv)
    total = len(df)
    print(f"  {total} registros")

    df_clean = df.dropna(subset=features)
    print(f"  {len(df_clean)} registros con features completas")

    if len(df_clean) == 0:
        print("ERROR: ningún registro tiene todas las features.")
        sys.exit(1)

    X = df_clean[features].values
    X_scaled = scaler.transform(X)
    y_pred = model.predict(X_scaled)
    y_pred_i = np.round(y_pred).astype(int).clip(0)

    has_targets = all(t in df_clean.columns for t in TARGETS)
    has_datetime = 'datetime' in df_clean.columns

    if show_last:
        subset = df_clean.iloc[-n_show:] if n_show else df_clean
        pred_sub = y_pred_i[-n_show:] if n_show else y_pred_i
    elif n_show:
        subset = df_clean.iloc[:n_show]
        pred_sub = y_pred_i[:n_show]
    else:
        subset = df_clean
        pred_sub = y_pred_i

    # ========================================================
    # CABECERA
    # ========================================================
    print()
    print("=" * 85)
    print("PREDICCIONES DE RASTROS DE FANTASMAS")
    print("Columnas: Real|Pred para cada ventana (si hay targets disponibles)")
    print("=" * 85)

    header = f"{'#':<5} {'Fecha':<22} {'Tipo':<7}"
    for t in TARGETS:
        lbl = t[7:] + 'm'
        header += f" {'R|P_'+lbl:<10}" if has_targets else f" {'Pred_'+lbl:<8}"
    print(header)
    print("-" * 85)

    for row_i, (_, row) in enumerate(subset.iterrows()):
        tipo = "ALTO" if row.get('ghost_type', 0) == 1 else "BAJO"
        fecha = str(row['datetime'])[:19] if has_datetime else f"#{row_i}"
        line = f"{row_i:<5} {fecha:<22} {tipo:<7}"

        for ti, t in enumerate(TARGETS):
            pred = pred_sub[row_i, ti]
            if has_targets and not np.isnan(row.get(t, float('nan'))):
                real = int(row[t])
                diff = pred - real
                marker = " " if diff == 0 else ("+" if diff > 0 else "-")
                line += f" {real}|{pred}{marker}{'':5}"
            else:
                line += f" {pred:<8}"
        print(line)

    print("=" * 85)

    # ========================================================
    # RESUMEN ESTADÍSTICO
    # ========================================================
    print(f"\nTotal predicciones generadas: {len(df_clean)}")
    print("\nDistribución de predicciones:")
    print(f"{'Ventana':<14} {'Min':>5} {'Máx':>5} {'Media':>8} {'Mediana':>8}")
    print("-" * 45)
    for i, t in enumerate(TARGETS):
        col = y_pred_i[:, i]
        print(f"{t:<14} {col.min():>5} {col.max():>5} {col.mean():>8.2f} {np.median(col):>8.1f}")

    if has_targets:
        from sklearn.metrics import mean_absolute_error
        y_real = df_clean[TARGETS].values
        print("\nMAE en el conjunto predicho:")
        for i, t in enumerate(TARGETS):
            mask = ~np.isnan(y_real[:, i])
            if mask.sum() > 0:
                mae = mean_absolute_error(y_real[mask, i], y_pred_i[mask, i])
                print(f"  {t}: {mae:.3f}")

    # Guardar predicciones a CSV
    out_path = input_csv.replace('.csv', '_predictions.csv')
    out_df = df_clean.copy()
    for i, t in enumerate(TARGETS):
        out_df[f'pred_{t}'] = y_pred_i[:, i]
    out_df.to_csv(out_path, index=False)
    print(f"\nPredicciones guardadas en: {out_path}")

if __name__ == '__main__':
    main()
