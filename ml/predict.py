#!/usr/bin/env python3
"""Carga la LSTM y el scaler persistidos y genera predicciones reproducibles."""

from __future__ import annotations

import argparse
import csv
import json
import math
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
)


HERE = Path(__file__).resolve().parent


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input_csv")
    parser.add_argument(
        "--model", default=str(HERE / "model_fantasmas_lstm.npz")
    )
    parser.add_argument(
        "--scaler", default=str(HERE / "scaler_params_lstm.npz")
    )
    parser.add_argument(
        "--config", default=str(HERE / "model_config_lstm.json")
    )
    parser.add_argument("--output", default=None)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--last", type=int, default=None)
    group.add_argument("--limit", type=int, default=None)
    return parser.parse_args()


def _optional_actual(row: dict, target: str) -> float | None:
    text = str(row.get(target, "")).strip()
    if not text:
        return None
    try:
        value = float(text)
    except ValueError:
        return None
    return value if math.isfinite(value) else None


def main() -> int:
    args = arguments()
    model, target_mean, target_scale, sequence_length = LSTMRegressor.load(
        args.model
    )
    preprocessor = Preprocessor.load(args.scaler)
    with open(args.config, encoding="utf-8") as handle:
        config = json.load(handle)
    if config.get("architecture") != "LSTM":
        raise ValueError("El artefacto configurado no es LSTM")

    rows, _ = load_feature_csv(args.input_csv, require_targets=False)
    features = preprocessor.transform(rows)
    if features.shape[1] != model.input_size:
        raise ValueError("El CSV no coincide con el esquema persistido")
    sequences, _, indices = build_sequences(
        features, None, range(len(rows)), sequence_length
    )
    if not len(sequences):
        raise ValueError(
            f"Se necesitan al menos {sequence_length} eventos para predecir"
        )
    normalized_prediction = model.predict(sequences)
    prediction = enforce_count_constraints(
        normalized_prediction * target_scale + target_mean
    )

    output = args.output
    if output is None:
        source = Path(args.input_csv)
        output = str(source.with_name(f"{source.stem}_lstm_predictions.csv"))
    Path(output).parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "event_id",
        "event_timestamp",
        "event_date",
        "event_hour",
        "event_minute",
        "ghost_type",
        "relocation",
    ]
    for target in TARGETS:
        fieldnames.append(f"prediction_{target}")
        fieldnames.append(f"actual_{target}")
    with open(output, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for prediction_index, source_index in enumerate(indices):
            source = rows[int(source_index)]
            result = {name: source.get(name, "") for name in fieldnames[:7]}
            for target_index, target in enumerate(TARGETS):
                result[f"prediction_{target}"] = float(
                    prediction[prediction_index, target_index]
                )
                actual = _optional_actual(source, target)
                result[f"actual_{target}"] = "" if actual is None else actual
            writer.writerow(result)

    display_indices = np.arange(len(indices))
    if args.last is not None:
        if args.last < 1:
            raise ValueError("--last debe ser positivo")
        display_indices = display_indices[-args.last :]
    elif args.limit is not None:
        if args.limit < 1:
            raise ValueError("--limit debe ser positivo")
        display_indices = display_indices[: args.limit]

    print("Predicciones LSTM de rastros futuros")
    print(
        f"{'Fecha':<20} {'Tipo':<5} {'Evento':<10} "
        + " ".join(f"{target:>9}" for target in TARGETS)
    )
    for prediction_index in display_indices:
        source = rows[int(indices[prediction_index])]
        values = " ".join(
            f"{prediction[prediction_index, target_index]:>9.2f}"
            for target_index in range(len(TARGETS))
        )
        print(
            f"{source.get('event_date', '')} "
            f"{int(float(source.get('event_hour', 0))):02d}:"
            f"{int(float(source.get('event_minute', 0))):02d} "
            f"{source.get('ghost_type', ''):<5} "
            f"{source.get('relocation', ''):<10} {values}"
        )
    print(f"\nPredicciones generadas: {len(indices)}")
    print(f"Guardadas en: {output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, AssertionError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
