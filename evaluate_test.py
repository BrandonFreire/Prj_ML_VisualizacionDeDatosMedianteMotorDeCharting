#!/usr/bin/env python3
"""Evalúa la GRU entrenada sobre los eventos de test de julio.

El archivo ``test_preprocessed.npz`` ya contiene X transformada con el
preprocesador ajustado en entrenamiento. Por eso este programa recarga
``scaler.joblib`` para validar la compatibilidad del artefacto, pero nunca
vuelve a ajustar ni a transformar la data de test: así se evita leakage.
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any

import joblib
import numpy as np
import pandas as pd
import torch
from torch import nn
from torch.utils.data import DataLoader, TensorDataset

from train_model import GhostGRURegressor, ModelConfig, TARGET_NAMES


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Evalúa trained_model.pt contra los rastros reales de julio."
    )
    parser.add_argument(
        "--test",
        type=Path,
        default=Path("artifacts/preprocessed/test_preprocessed.npz"),
        help="NPZ de test ya transformado por el preprocesador de entrenamiento.",
    )
    parser.add_argument(
        "--metadata",
        type=Path,
        default=Path("artifacts/preprocessed/test_metadata.csv"),
        help="CSV con fecha, hora e identificadores de cada evento de test.",
    )
    parser.add_argument(
        "--scaler",
        type=Path,
        default=Path("artifacts/preprocessed/scaler.joblib"),
        help="Bundle de escalado ajustado exclusivamente con entrenamiento.",
    )
    parser.add_argument(
        "--model",
        type=Path,
        default=Path("artifacts/models/trained_model.pt"),
        help="Checkpoint de la GRU entrenada.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("artifacts/evaluation/test_predictions_comparison.csv"),
        help="CSV de salida con metadata, rastros reales y predicciones.",
    )
    parser.add_argument(
        "--report",
        type=Path,
        default=Path("artifacts/evaluation/test_metrics.json"),
        help="JSON de métricas y trazabilidad de la evaluación.",
    )
    parser.add_argument("--batch-size", type=int, default=512)
    parser.add_argument("--device", choices=("auto", "cpu", "cuda"), default="auto")
    return parser.parse_args()


def ensure_file(path: Path, label: str) -> None:
    if not path.is_file():
        raise FileNotFoundError(f"No existe {label}: {path}")


def resolve_device(requested: str) -> torch.device:
    if requested == "auto":
        return torch.device("cuda" if torch.cuda.is_available() else "cpu")
    if requested == "cuda" and not torch.cuda.is_available():
        raise RuntimeError("Se solicitó CUDA, pero PyTorch no detecta una GPU disponible.")
    return torch.device(requested)


def load_test_data(path: Path) -> tuple[np.ndarray, np.ndarray, np.ndarray, list[str]]:
    """Carga X, Y y disponibilidad de etiquetas sin alterar sus filas."""
    ensure_file(path, "el dataset de test")
    with np.load(path, allow_pickle=False) as data:
        required = {"X", "Y"}
        missing = required.difference(data.files)
        if missing:
            raise ValueError(f"NPZ incompleto; faltan las claves: {sorted(missing)}")
        x = np.asarray(data["X"], dtype=np.float32)
        y = np.asarray(data["Y"], dtype=np.float32)
        available = np.asarray(
            data["target_available"]
            if "target_available" in data.files
            else np.isfinite(y).all(axis=1),
            dtype=bool,
        )
        target_names = [
            str(value)
            for value in (
                data["target_names"] if "target_names" in data.files else np.asarray(TARGET_NAMES)
            )
        ]

    if x.ndim != 2 or y.ndim != 2 or len(x) != len(y):
        raise ValueError("NPZ inválido: se esperaba X=(N,F) e Y=(N,4) con el mismo N.")
    if y.shape[1] != len(TARGET_NAMES):
        raise ValueError(f"El modelo requiere {len(TARGET_NAMES)} targets; se recibieron {y.shape[1]}.")
    if available.shape != (len(x),):
        raise ValueError("target_available debe tener una marca booleana por fila de test.")
    if len(target_names) != y.shape[1]:
        raise ValueError("target_names no coincide con las columnas de Y.")
    if not np.isfinite(x).all():
        raise ValueError("X contiene valores no finitos; regenere el preprocesamiento antes de evaluar.")
    return x, y, available, target_names


def load_metadata(path: Path, expected_rows: int) -> pd.DataFrame:
    ensure_file(path, "el CSV de metadatos")
    metadata = pd.read_csv(path)
    if len(metadata) != expected_rows:
        raise ValueError(
            f"Metadatos y NPZ no están alineados: metadata={len(metadata)}, NPZ={expected_rows}."
        )
    return metadata


def load_scaler_bundle(path: Path, input_size: int, target_names: list[str]) -> dict[str, Any]:
    """Recarga y valida el bundle que generó la X ya preprocesada.

    No se llama ``transform`` aquí: hacerlo sobre un NPZ que ya fue escalado
    aplicaría el escalado por segunda vez y produciría predicciones inválidas.
    """
    ensure_file(path, "el bundle de escalado")
    bundle = joblib.load(path)
    if not isinstance(bundle, dict) or "preprocessor" not in bundle:
        raise ValueError("scaler.joblib no contiene el bundle de preprocesamiento esperado.")

    bundle_targets = [str(value) for value in bundle.get("target_columns", TARGET_NAMES)]
    if bundle_targets != target_names:
        raise ValueError(
            "El orden de targets de scaler.joblib no coincide con test_preprocessed.npz: "
            f"{bundle_targets} != {target_names}"
        )

    preprocessor = bundle["preprocessor"]
    if hasattr(preprocessor, "get_feature_names_out"):
        transformed_size = len(preprocessor.get_feature_names_out())
        if transformed_size != input_size:
            raise ValueError(
                "El número de features del scaler no coincide con X de test: "
                f"{transformed_size} != {input_size}."
            )
    return bundle


def torch_load_checkpoint(path: Path, device: torch.device) -> dict[str, Any]:
    """Carga un checkpoint local de manera compatible con PyTorch 2.x."""
    ensure_file(path, "el modelo entrenado")
    try:
        checkpoint = torch.load(path, map_location=device, weights_only=True)
    except TypeError:  # PyTorch antiguo sin el argumento weights_only.
        checkpoint = torch.load(path, map_location=device)
    if not isinstance(checkpoint, dict):
        raise ValueError("El checkpoint no tiene el formato de diccionario esperado.")
    return checkpoint


def load_model(
    path: Path, device: torch.device, input_size: int, target_names: list[str]
) -> tuple[nn.Module, int, dict[str, Any]]:
    checkpoint = torch_load_checkpoint(path, device)
    required = {"model_state_dict", "model_config", "sequence_length", "target_names"}
    missing = required.difference(checkpoint)
    if missing:
        raise ValueError(f"Checkpoint incompleto; faltan las claves: {sorted(missing)}")

    checkpoint_targets = [str(value) for value in checkpoint["target_names"]]
    if checkpoint_targets != target_names:
        raise ValueError(
            "El orden de targets del modelo no coincide con el NPZ de test: "
            f"{checkpoint_targets} != {target_names}"
        )

    config = ModelConfig(**checkpoint["model_config"])
    if config.input_size != input_size:
        raise ValueError(
            "El modelo y test_preprocessed.npz usan diferente número de features: "
            f"modelo={config.input_size}, test={input_size}."
        )
    if config.output_size != len(target_names):
        raise ValueError("La salida configurada en el modelo no coincide con los cuatro targets.")

    sequence_length = int(checkpoint["sequence_length"])
    if sequence_length < 1:
        raise ValueError("sequence_length del checkpoint debe ser >= 1.")
    model = GhostGRURegressor(config).to(device)
    model.load_state_dict(checkpoint["model_state_dict"])
    model.eval()
    return model, sequence_length, checkpoint


def make_sequences(values: np.ndarray, sequence_length: int) -> tuple[np.ndarray, np.ndarray]:
    """Crea ventanas y los índices de la fila final de cada ventana."""
    if len(values) < sequence_length:
        raise ValueError(
            f"Se requieren {sequence_length} filas para una ventana; solo hay {len(values)}."
        )
    sequences = np.stack(
        [values[start : start + sequence_length] for start in range(len(values) - sequence_length + 1)]
    )
    end_indices = np.arange(sequence_length - 1, len(values))
    return sequences, end_indices


@torch.no_grad()
def predict(model: nn.Module, sequences: np.ndarray, batch_size: int, device: torch.device) -> np.ndarray:
    if batch_size < 1:
        raise ValueError("--batch-size debe ser >= 1.")
    loader = DataLoader(TensorDataset(torch.from_numpy(sequences)), batch_size=batch_size, shuffle=False)
    outputs: list[np.ndarray] = []
    for (features,) in loader:
        outputs.append(model(features.to(device)).cpu().numpy())
    return np.concatenate(outputs, axis=0)


def metric_report(
    actual: np.ndarray, predicted: np.ndarray, target_names: list[str]
) -> dict[str, dict[str, float | int | None]]:
    report: dict[str, dict[str, float | int | None]] = {}
    for index, name in enumerate(target_names):
        observed, estimated = actual[:, index], predicted[:, index]
        error = estimated - observed
        ss_res = float(np.square(error).sum())
        ss_tot = float(np.square(observed - observed.mean()).sum())
        report[name] = {
            "n": int(len(observed)),
            "mae": float(np.abs(error).mean()),
            "rmse": float(math.sqrt(np.square(error).mean())),
            "r2": float(1.0 - ss_res / ss_tot) if ss_tot > 0 else None,
        }
    return report


def build_comparison(
    metadata: pd.DataFrame,
    actual: np.ndarray,
    predictions: np.ndarray,
    sequence_end_indices: np.ndarray,
    eligible_for_metrics: np.ndarray,
    target_names: list[str],
    sequence_length: int,
) -> pd.DataFrame:
    """Devuelve una fila por evento y deja explícita la falta de historial inicial."""
    comparison = metadata.copy()
    comparison["sequence_length"] = sequence_length
    comparison["prediction_available"] = False
    comparison["included_in_metrics"] = False

    for target_index, name in enumerate(target_names):
        comparison[f"actual_{name}"] = actual[:, target_index]
        comparison[f"prediction_{name}"] = np.nan
        comparison[f"residual_{name}"] = np.nan

    comparison.loc[sequence_end_indices, "prediction_available"] = True
    comparison.loc[sequence_end_indices, "included_in_metrics"] = eligible_for_metrics
    for target_index, name in enumerate(target_names):
        predicted_column = f"prediction_{name}"
        residual_column = f"residual_{name}"
        comparison.loc[sequence_end_indices, predicted_column] = predictions[:, target_index]
        comparison.loc[sequence_end_indices, residual_column] = (
            predictions[:, target_index] - actual[sequence_end_indices, target_index]
        )
    return comparison


def print_metrics(metrics: dict[str, dict[str, float | int | None]]) -> None:
    print("\nMétricas finales — test de julio")
    print(f"{'Target':<8} {'N':>7} {'MAE':>12} {'RMSE':>12} {'R²':>12}")
    for target, values in metrics.items():
        r2 = "N/A" if values["r2"] is None else f"{float(values['r2']):.6f}"
        print(
            f"{target:<8} {int(values['n']):>7} {float(values['mae']):>12.6f} "
            f"{float(values['rmse']):>12.6f} {r2:>12}"
        )


def main() -> None:
    options = parse_args()
    device = resolve_device(options.device)
    x, y, target_available, target_names = load_test_data(options.test)
    metadata = load_metadata(options.metadata, len(x))
    scaler_bundle = load_scaler_bundle(options.scaler, x.shape[1], target_names)
    model, sequence_length, checkpoint = load_model(
        options.model, device, x.shape[1], target_names
    )
    sequences, sequence_end_indices = make_sequences(x, sequence_length)
    predictions = predict(model, sequences, options.batch_size, device)

    # Solo se puntúan ventanas cuyo último evento tiene los cuatro rastros reales.
    target_complete = np.isfinite(y).all(axis=1)
    eligible = target_available[sequence_end_indices] & target_complete[sequence_end_indices]
    if not eligible.any():
        raise ValueError("No hay ventanas de test con los cuatro targets observados para calcular métricas.")
    metrics = metric_report(y[sequence_end_indices][eligible], predictions[eligible], target_names)
    comparison = build_comparison(
        metadata,
        y,
        predictions,
        sequence_end_indices,
        eligible,
        target_names,
        sequence_length,
    )

    options.output.parent.mkdir(parents=True, exist_ok=True)
    comparison.to_csv(options.output, index=False)
    report = {
        "dataset": str(options.test),
        "metadata": str(options.metadata),
        "model": str(options.model),
        "scaler": str(options.scaler),
        "scaler_kind": scaler_bundle.get("scaler_kind"),
        "device": str(device),
        "target_names": target_names,
        "sequence_length": sequence_length,
        "total_test_rows": int(len(x)),
        "rows_without_initial_history": int(sequence_length - 1),
        "prediction_rows": int(len(predictions)),
        "metric_rows": int(eligible.sum()),
        "checkpoint_best_validation_mse": checkpoint.get("best_validation_mse"),
        "metrics": metrics,
        "comparison_csv": str(options.output),
    }
    options.report.parent.mkdir(parents=True, exist_ok=True)
    options.report.write_text(json.dumps(report, indent=2, ensure_ascii=False, allow_nan=False), encoding="utf-8")

    print_metrics(metrics)
    print(f"\nComparación exportada: {options.output}")
    print(f"Reporte JSON exportado: {options.report}")
    print(
        f"Filas: {len(x):,} total | {len(predictions):,} con predicción | "
        f"{int(eligible.sum()):,} incluidas en métricas."
    )


if __name__ == "__main__":
    main()
