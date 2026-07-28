#!/usr/bin/env python3
"""Evalua el modelo LSTM persistido sobre features del 1 al 24 de julio."""

from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

import numpy as np

from lstm_core import (
    TARGETS,
    LSTMRegressor,
    Preprocessor,
    build_sequences,
    enforce_count_constraints,
    load_feature_csv,
    regression_metrics,
    sha256_file,
    write_json,
)


HERE = Path(__file__).resolve().parent


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "input_csv", nargs="?", default=str(HERE / "features_test.csv")
    )
    parser.add_argument(
        "--model", default=str(HERE / "model_fantasmas_lstm.npz")
    )
    parser.add_argument(
        "--scaler", default=str(HERE / "scaler_params_lstm.npz")
    )
    parser.add_argument(
        "--config", default=str(HERE / "model_config_lstm.json")
    )
    parser.add_argument(
        "--metrics", default=str(HERE / "test_metrics_lstm.json")
    )
    parser.add_argument("--predictions", default=None)
    parser.add_argument(
        "--enforce-project-range",
        action="store_true",
        help="Exige fechas 2026-07-01..2026-07-24.",
    )
    return parser.parse_args()


def main() -> int:
    args = arguments()
    print(f"Cargando modelo LSTM: {args.model}")
    model, target_mean, target_scale, sequence_length = LSTMRegressor.load(
        args.model
    )
    preprocessor = Preprocessor.load(args.scaler)
    with open(args.config, encoding="utf-8") as handle:
        config = json.load(handle)
    if config.get("architecture") != "LSTM":
        raise ValueError("La configuracion no declara arquitectura LSTM")
    if config.get("convolutional_layers") not in ([], None):
        raise ValueError("La configuracion contiene capas convolucionales")

    print(f"Cargando test externo: {args.input_csv}")
    rows, targets = load_feature_csv(args.input_csv, require_targets=True)
    assert targets is not None
    dates = [row.get("event_date", "") for row in rows]
    if args.enforce_project_range and any(
        not ("2026-07-01" <= date <= "2026-07-24") for date in dates
    ):
        raise ValueError(
            "El test del proyecto solo admite datos del 1 al 24 de julio de 2026"
        )

    features = preprocessor.transform(rows)
    if features.shape[1] != model.input_size:
        raise ValueError(
            f"Dimensiones incompatibles: scaler={features.shape[1]}, "
            f"modelo={model.input_size}"
        )
    sequences, sequence_targets, indices = build_sequences(
        features,
        targets,
        range(len(rows)),
        sequence_length,
    )
    assert sequence_targets is not None
    if not len(sequences):
        raise ValueError("No hay historia suficiente para formar secuencias")

    normalized_prediction = model.predict(sequences)
    prediction = enforce_count_constraints(
        normalized_prediction * target_scale + target_mean
    )
    metrics = regression_metrics(sequence_targets, prediction)

    prediction_path = args.predictions
    if prediction_path is None:
        source = Path(args.input_csv)
        prediction_path = str(
            source.with_name(f"{source.stem}_lstm_predictions.csv")
        )
    Path(prediction_path).parent.mkdir(parents=True, exist_ok=True)
    with open(prediction_path, "w", newline="", encoding="utf-8") as handle:
        header = [
            "event_id",
            "event_timestamp",
            "event_date",
            "event_hour",
            "event_minute",
            "event_index",
            "ghost_index",
        ]
        for target in TARGETS:
            header.extend((f"actual_{target}", f"prediction_{target}", f"residual_{target}"))
        writer = csv.DictWriter(handle, fieldnames=header)
        writer.writeheader()
        for sequence_row, source_index in enumerate(indices):
            source = rows[int(source_index)]
            output = {name: source.get(name, "") for name in header[:7]}
            for target_index, target in enumerate(TARGETS):
                actual = float(sequence_targets[sequence_row, target_index])
                predicted = float(prediction[sequence_row, target_index])
                output[f"actual_{target}"] = actual
                output[f"prediction_{target}"] = predicted
                output[f"residual_{target}"] = predicted - actual
            writer.writerow(output)

    payload = {
        "architecture": "LSTM",
        "convolutional_layers": [],
        "test_csv": str(Path(args.input_csv).resolve()),
        "test_sha256": sha256_file(args.input_csv),
        "date_min": min(dates),
        "date_max": max(dates),
        "model": str(Path(args.model).resolve()),
        "scaler_reloaded_transform_only": str(Path(args.scaler).resolve()),
        "sequence_length": sequence_length,
        "input_rows": len(rows),
        "prediction_rows": len(indices),
        "rows_without_initial_history": sequence_length - 1,
        "metrics": metrics,
        "comparison_csv": str(Path(prediction_path).resolve()),
    }
    write_json(args.metrics, payload)

    print("\nEvaluacion externa de julio:")
    print(
        f"{'Ventana':<10} {'MAE':>8} {'RMSE':>8} {'R2':>9} "
        f"{'Exacta':>9} {'±1':>9}"
    )
    for target in TARGETS:
        metric = metrics[target]
        print(
            f"{target:<10} {metric['mae']:>8.3f} {metric['rmse']:>8.3f} "
            f"{metric['r2']:>9.3f} {metric['exact_accuracy']:>8.1f}% "
            f"{metric['within_one_accuracy']:>8.1f}%"
        )
    print(f"\nMetricas guardadas:     {args.metrics}")
    print(f"Comparacion guardada:   {prediction_path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, AssertionError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
