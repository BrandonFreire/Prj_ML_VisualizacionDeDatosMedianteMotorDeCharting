#!/usr/bin/env python3
"""Entrena una LSTM causal multi-salida para Y_3m, Y_5m, Y_10m y Y_15m."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

from lstm_core import (
    CATEGORICAL_COLUMNS,
    METADATA_COLUMNS,
    NUMERIC_COLUMNS,
    TARGETS,
    LSTMRegressor,
    Preprocessor,
    build_sequences,
    enforce_count_constraints,
    load_feature_csv,
    regression_metrics,
    sha256_file,
    target_scaler,
    train_epochs,
    write_json,
)


HERE = Path(__file__).resolve().parent


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "input_csv",
        nargs="?",
        default=str(HERE / "features_train.csv"),
        help="Features extraidas exclusivamente de abril-junio.",
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
        "--report", default=str(HERE / "training_report_lstm.json")
    )
    parser.add_argument("--sequence-length", type=int, default=16)
    parser.add_argument("--hidden-size", type=int, default=32)
    parser.add_argument("--epochs", type=int, default=30)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--learning-rate", type=float, default=1e-3)
    parser.add_argument("--validation-fraction", type=float, default=0.20)
    parser.add_argument("--patience", type=int, default=6)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument(
        "--enforce-project-range",
        action="store_true",
        help="Exige que todas las filas pertenezcan a 2026-04-01..2026-06-30.",
    )
    return parser.parse_args()


def main() -> int:
    args = arguments()
    if args.sequence_length < 2:
        raise ValueError("--sequence-length debe ser al menos 2")
    if args.hidden_size < 2 or args.epochs < 1 or args.batch_size < 1:
        raise ValueError("hidden-size, epochs y batch-size deben ser positivos")
    if not 0.05 <= args.validation_fraction <= 0.40:
        raise ValueError("--validation-fraction debe estar entre 0.05 y 0.40")

    print(f"Cargando features de entrenamiento: {args.input_csv}")
    rows, targets = load_feature_csv(args.input_csv, require_targets=True)
    assert targets is not None
    if len(rows) < max(40, args.sequence_length * 3):
        raise ValueError("No hay suficientes eventos para entrenar y validar")
    dates = [row.get("event_date", "") for row in rows]
    if args.enforce_project_range and any(
        not ("2026-04-01" <= date <= "2026-06-30") for date in dates
    ):
        raise ValueError(
            "El entrenamiento del proyecto solo admite datos de abril a junio de 2026"
        )

    split = int(len(rows) * (1.0 - args.validation_fraction))
    split = max(args.sequence_length, min(split, len(rows) - args.sequence_length))
    validation_start_time = int(float(rows[split]["event_timestamp"]))
    train_end = split
    while (
        train_end > args.sequence_length
        and int(float(rows[train_end - 1]["event_timestamp"])) + 15 * 60
        >= validation_start_time
    ):
        train_end -= 1
    if train_end < args.sequence_length * 2:
        raise ValueError("La purga temporal deja muy pocas filas de entrenamiento")

    selection_preprocessor = Preprocessor.fit(rows[:train_end])
    selection_features = selection_preprocessor.transform(rows)
    selection_target_mean, selection_target_scale = target_scaler(
        targets[:train_end]
    )
    normalized_targets = (
        targets - selection_target_mean
    ) / selection_target_scale

    train_x, train_y, train_indices = build_sequences(
        selection_features,
        normalized_targets,
        range(args.sequence_length - 1, train_end),
        args.sequence_length,
    )
    validation_x, validation_y, validation_indices = build_sequences(
        selection_features,
        normalized_targets,
        range(split, len(rows)),
        args.sequence_length,
    )
    assert train_y is not None and validation_y is not None
    if not len(train_x) or not len(validation_x):
        raise ValueError("No se pudieron formar secuencias de train/validacion")

    print(
        f"Eventos: {len(rows)} | train purgado: {len(train_indices)} | "
        f"validacion: {len(validation_indices)}"
    )
    print(
        f"Arquitectura: LSTM({selection_features.shape[1]} -> "
        f"{args.hidden_size}) -> Dense(4), sin CNN"
    )

    selection_model = LSTMRegressor(
        input_size=selection_features.shape[1],
        hidden_size=args.hidden_size,
        output_size=len(TARGETS),
        seed=args.seed,
    )
    history, _, best_epoch = train_epochs(
        selection_model,
        train_x,
        train_y,
        epochs=args.epochs,
        batch_size=args.batch_size,
        learning_rate=args.learning_rate,
        seed=args.seed,
        validation=(validation_x, validation_y),
        patience=args.patience,
    )
    for record in history:
        print(
            f"Epoca {int(record['epoch']):02d} "
            f"train_mse={record['train_mse']:.5f} "
            f"val_mse={record['validation_mse']:.5f}"
        )

    validation_normalized = selection_model.predict(validation_x)
    validation_prediction = enforce_count_constraints(
        validation_normalized * selection_target_scale + selection_target_mean
    )
    validation_actual = targets[validation_indices]
    validation_metrics = regression_metrics(
        validation_actual, validation_prediction
    )

    final_preprocessor = Preprocessor.fit(rows)
    final_features = final_preprocessor.transform(rows)
    final_target_mean, final_target_scale = target_scaler(targets)
    final_normalized_targets = (
        targets - final_target_mean
    ) / final_target_scale
    final_x, final_y, final_indices = build_sequences(
        final_features,
        final_normalized_targets,
        range(args.sequence_length - 1, len(rows)),
        args.sequence_length,
    )
    assert final_y is not None
    final_model = LSTMRegressor(
        input_size=final_features.shape[1],
        hidden_size=args.hidden_size,
        output_size=len(TARGETS),
        seed=args.seed,
    )
    final_history, _, _ = train_epochs(
        final_model,
        final_x,
        final_y,
        epochs=best_epoch,
        batch_size=args.batch_size,
        learning_rate=args.learning_rate,
        seed=args.seed,
        validation=None,
    )

    Path(args.model).parent.mkdir(parents=True, exist_ok=True)
    Path(args.scaler).parent.mkdir(parents=True, exist_ok=True)
    final_model.save(
        args.model,
        final_target_mean,
        final_target_scale,
        args.sequence_length,
    )
    final_preprocessor.save(args.scaler)

    model_features = Preprocessor.model_feature_names()
    forbidden = set(METADATA_COLUMNS) | set(TARGETS)
    if forbidden.intersection(model_features):
        raise AssertionError("Metadatos o targets ingresaron al tensor X")

    config = {
        "architecture": "LSTM",
        "convolutional_layers": [],
        "input_size": int(final_features.shape[1]),
        "hidden_size": args.hidden_size,
        "lstm_layers": 1,
        "output_size": len(TARGETS),
        "targets": list(TARGETS),
        "sequence_length": args.sequence_length,
        "numeric_features": list(NUMERIC_COLUMNS),
        "categorical_features": list(CATEGORICAL_COLUMNS),
        "model_feature_names": list(model_features),
        "metadata_excluded_from_X": list(METADATA_COLUMNS),
        "prediction_constraints": {
            "nonnegative": True,
            "monotonic_across_windows": True,
            "maximum_per_window": [3, 5, 10, 15],
        },
    }
    write_json(args.config, config)
    report = {
        "architecture": "LSTM recurrente sin capas convolucionales",
        "source_csv": str(Path(args.input_csv).resolve()),
        "source_sha256": sha256_file(args.input_csv),
        "date_min": min(dates),
        "date_max": max(dates),
        "rows_complete": len(rows),
        "selection": {
            "split_index": split,
            "train_end_after_15m_purge": train_end,
            "validation_start_timestamp": validation_start_time,
            "best_epoch": best_epoch,
            "history": history,
            "validation_metrics": validation_metrics,
            "scaler_fit_rows": train_end,
        },
        "final_fit": {
            "rows": len(rows),
            "sequences": len(final_indices),
            "epochs": best_epoch,
            "history": final_history,
            "scaler_fit_only_on_april_june_features": True,
        },
        "artifacts": {
            "model": str(Path(args.model).resolve()),
            "scaler": str(Path(args.scaler).resolve()),
            "config": str(Path(args.config).resolve()),
        },
        "metadata_excluded_from_X": list(METADATA_COLUMNS),
        "targets_predicted_simultaneously": list(TARGETS),
    }
    write_json(args.report, report)

    print("\nValidacion temporal (antes del ajuste final):")
    for target in TARGETS:
        metric = validation_metrics[target]
        print(
            f"  {target}: MAE={metric['mae']:.3f} "
            f"RMSE={metric['rmse']:.3f} R2={metric['r2']:.3f}"
        )
    print(f"\nModelo LSTM guardado: {args.model}")
    print(f"Scaler guardado:      {args.scaler}")
    print(f"Configuracion:         {args.config}")
    print(f"Reporte:               {args.report}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, AssertionError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
