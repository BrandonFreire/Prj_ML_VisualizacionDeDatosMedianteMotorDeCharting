#!/usr/bin/env python3
"""Utilidades compartidas del pipeline LSTM, sin dependencias fuera de NumPy."""

from __future__ import annotations

import csv
import hashlib
import json
import math
import os
import warnings
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Sequence, Tuple

import numpy as np


TARGETS = ("Y_3m", "Y_5m", "Y_10m", "Y_15m")
TARGET_LIMITS = np.asarray((3.0, 5.0, 10.0, 15.0), dtype=np.float32)
METADATA_COLUMNS = (
    "event_id",
    "event_timestamp",
    "event_date",
    "event_hour",
    "event_minute",
    "event_index",
    "ghost_index",
    "complete",
)
CATEGORICAL_COLUMNS = ("ghost_type", "relocation")
CATEGORY_LEVELS = {
    "ghost_type": ("high", "low"),
    "relocation": ("appearance", "move"),
}


def numeric_feature_columns() -> Tuple[str, ...]:
    columns: List[str] = [
        "ghost_price",
        "ghost_hlc3",
        "atr_1m",
        "volume_1m",
        "volume_ema9_1m",
    ]
    for tf in (1, 10, 60):
        columns.extend(
            (
                f"tf{tf}_ob_dist_pips",
                f"tf{tf}_ob_width_pips",
                f"tf{tf}_fvg_dist_pips",
                f"tf{tf}_fvg_width_pips",
                f"tf{tf}_fib_dist_pips",
                f"tf{tf}_vwap_dist_pips",
                f"tf{tf}_vwap_band1_dist_pips",
                f"tf{tf}_vwap_band2_dist_pips",
                f"tf{tf}_vp_poc_dist_pips",
                f"tf{tf}_vp_vah_dist_pips",
                f"tf{tf}_vp_val_dist_pips",
                f"tf{tf}_bos_choch_dist_pips",
                f"tf{tf}_eqh_eql_dist_pips",
                f"tf{tf}_sweep_grab_run_dist_pips",
                f"tf{tf}_supply_demand_dist_pips",
                f"tf{tf}_supply_demand_width_pips",
                f"tf{tf}_channel_dist_pips",
                f"tf{tf}_channel_width_pips",
            )
        )
    columns.extend(("sr_4h_dist_pips", "sr_d_dist_pips", "sr_w_dist_pips"))
    return tuple(columns)


NUMERIC_COLUMNS = numeric_feature_columns()


def sha256_file(path: os.PathLike[str] | str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _float_or_nan(value: object) -> float:
    if value is None:
        return math.nan
    text = str(value).strip()
    if not text:
        return math.nan
    try:
        parsed = float(text)
    except (TypeError, ValueError):
        return math.nan
    return parsed if math.isfinite(parsed) else math.nan


def load_feature_csv(
    path: os.PathLike[str] | str,
    require_targets: bool,
) -> Tuple[List[Dict[str, str]], np.ndarray | None]:
    with open(path, newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        header = tuple(reader.fieldnames or ())
        required = set(NUMERIC_COLUMNS) | set(CATEGORICAL_COLUMNS) | {
            "event_timestamp"
        }
        if require_targets:
            required.update(TARGETS)
        missing = sorted(required.difference(header))
        if missing:
            raise ValueError(
                f"{path} no contiene columnas obligatorias: {', '.join(missing)}"
            )
        rows = [dict(row) for row in reader]
    if not rows:
        raise ValueError(f"{path} no contiene registros")

    rows.sort(key=lambda row: int(float(row["event_timestamp"])))
    previous = None
    for row in rows:
        timestamp = int(float(row["event_timestamp"]))
        if previous is not None and timestamp < previous:
            raise ValueError("Los eventos no estan ordenados cronologicamente")
        previous = timestamp

    targets = None
    if require_targets:
        kept_rows: List[Dict[str, str]] = []
        kept_targets: List[List[float]] = []
        for row in rows:
            values = [_float_or_nan(row.get(name)) for name in TARGETS]
            complete = str(row.get("complete", "1")).strip().lower()
            if complete in {"0", "false", "no"} or not all(
                math.isfinite(value) for value in values
            ):
                continue
            if any(value < 0 for value in values):
                continue
            if any(values[index] > TARGET_LIMITS[index] for index in range(4)):
                raise ValueError(
                    f"Target fuera de su ventana en evento {row.get('event_id', '?')}"
                )
            if any(values[index] > values[index + 1] for index in range(3)):
                raise ValueError(
                    f"Targets no monotonos en evento {row.get('event_id', '?')}"
                )
            kept_rows.append(row)
            kept_targets.append(values)
        rows = kept_rows
        if not rows:
            raise ValueError(f"{path} no contiene targets completos")
        targets = np.asarray(kept_targets, dtype=np.float32)
    return rows, targets


@dataclass
class Preprocessor:
    median: np.ndarray
    mean: np.ndarray
    scale: np.ndarray

    @classmethod
    def fit(cls, rows: Sequence[Dict[str, str]]) -> "Preprocessor":
        raw = cls._numeric_matrix(rows)
        with warnings.catch_warnings(), np.errstate(all="ignore"):
            warnings.simplefilter("ignore", category=RuntimeWarning)
            median = np.nanmedian(raw, axis=0)
        median = np.where(np.isfinite(median), median, 0.0)
        filled = np.where(np.isfinite(raw), raw, median)
        mean = filled.mean(axis=0)
        scale = filled.std(axis=0)
        scale = np.where(scale > 1e-12, scale, 1.0)
        return cls(
            median.astype(np.float64),
            mean.astype(np.float64),
            scale.astype(np.float64),
        )

    @staticmethod
    def _numeric_matrix(rows: Sequence[Dict[str, str]]) -> np.ndarray:
        return np.asarray(
            [
                [_float_or_nan(row.get(column)) for column in NUMERIC_COLUMNS]
                for row in rows
            ],
            dtype=np.float64,
        )

    @staticmethod
    def model_feature_names() -> Tuple[str, ...]:
        names = [f"numeric__{name}" for name in NUMERIC_COLUMNS]
        for column in CATEGORICAL_COLUMNS:
            names.extend(
                f"categorical__{column}_{level}"
                for level in CATEGORY_LEVELS[column]
            )
        return tuple(names)

    def transform(self, rows: Sequence[Dict[str, str]]) -> np.ndarray:
        raw = self._numeric_matrix(rows)
        filled = np.where(np.isfinite(raw), raw, self.median)
        numeric = (filled - self.mean) / self.scale
        categorical = np.zeros(
            (
                len(rows),
                sum(len(CATEGORY_LEVELS[name]) for name in CATEGORICAL_COLUMNS),
            ),
            dtype=np.float64,
        )
        offset = 0
        for column in CATEGORICAL_COLUMNS:
            levels = CATEGORY_LEVELS[column]
            lookup = {level: index for index, level in enumerate(levels)}
            for row_index, row in enumerate(rows):
                level_index = lookup.get(str(row.get(column, "")).strip().lower())
                if level_index is not None:
                    categorical[row_index, offset + level_index] = 1.0
            offset += len(levels)
        return np.concatenate((numeric, categorical), axis=1).astype(np.float32)

    def save(self, path: os.PathLike[str] | str) -> None:
        np.savez_compressed(
            path,
            median=self.median,
            mean=self.mean,
            scale=self.scale,
            numeric_columns=np.asarray(NUMERIC_COLUMNS),
            categorical_columns=np.asarray(CATEGORICAL_COLUMNS),
            model_feature_names=np.asarray(self.model_feature_names()),
            metadata_excluded=np.asarray(METADATA_COLUMNS),
            targets=np.asarray(TARGETS),
        )

    @classmethod
    def load(cls, path: os.PathLike[str] | str) -> "Preprocessor":
        with np.load(path, allow_pickle=False) as data:
            numeric = tuple(str(value) for value in data["numeric_columns"])
            categorical = tuple(str(value) for value in data["categorical_columns"])
            if numeric != NUMERIC_COLUMNS or categorical != CATEGORICAL_COLUMNS:
                raise ValueError(
                    "El esquema del scaler no coincide con el extractor activo"
                )
            return cls(
                data["median"].astype(np.float64),
                data["mean"].astype(np.float64),
                data["scale"].astype(np.float64),
            )


def build_sequences(
    features: np.ndarray,
    targets: np.ndarray | None,
    target_indices: Iterable[int],
    sequence_length: int,
) -> Tuple[np.ndarray, np.ndarray | None, np.ndarray]:
    valid_indices = np.asarray(
        [index for index in target_indices if index >= sequence_length - 1],
        dtype=np.int64,
    )
    if valid_indices.size == 0:
        empty_x = np.empty(
            (0, sequence_length, features.shape[1]), dtype=np.float32
        )
        empty_y = (
            np.empty((0, len(TARGETS)), dtype=np.float32)
            if targets is not None
            else None
        )
        return empty_x, empty_y, valid_indices
    sequences = np.stack(
        [
            features[index - sequence_length + 1 : index + 1]
            for index in valid_indices
        ]
    ).astype(np.float32)
    sequence_targets = (
        targets[valid_indices].astype(np.float32) if targets is not None else None
    )
    return sequences, sequence_targets, valid_indices


class LSTMRegressor:
    """Una capa LSTM seguida de una cabeza lineal de cuatro salidas."""

    def __init__(
        self,
        input_size: int,
        hidden_size: int,
        output_size: int = 4,
        seed: int = 42,
    ) -> None:
        self.input_size = int(input_size)
        self.hidden_size = int(hidden_size)
        self.output_size = int(output_size)
        rng = np.random.default_rng(seed)
        fan_in = self.input_size + self.hidden_size
        limit = math.sqrt(6.0 / (fan_in + 4 * self.hidden_size))
        self.W = rng.uniform(
            -limit, limit, size=(fan_in, 4 * self.hidden_size)
        ).astype(np.float32)
        self.b = np.zeros(4 * self.hidden_size, dtype=np.float32)
        self.b[self.hidden_size : 2 * self.hidden_size] = 1.0
        head_limit = math.sqrt(6.0 / (self.hidden_size + self.output_size))
        self.Wy = rng.uniform(
            -head_limit,
            head_limit,
            size=(self.hidden_size, self.output_size),
        ).astype(np.float32)
        self.by = np.zeros(self.output_size, dtype=np.float32)

    @property
    def parameters(self) -> Dict[str, np.ndarray]:
        return {"W": self.W, "b": self.b, "Wy": self.Wy, "by": self.by}

    @staticmethod
    def _sigmoid(value: np.ndarray) -> np.ndarray:
        value = np.clip(value, -40.0, 40.0)
        return 1.0 / (1.0 + np.exp(-value))

    def forward(
        self, sequences: np.ndarray, cache: bool = False
    ) -> Tuple[np.ndarray, list | None]:
        batch = sequences.shape[0]
        hidden = np.zeros((batch, self.hidden_size), dtype=np.float32)
        cell = np.zeros_like(hidden)
        history = [] if cache else None
        for step in range(sequences.shape[1]):
            current = sequences[:, step, :]
            combined = np.concatenate((current, hidden), axis=1)
            gates = combined @ self.W + self.b
            i = self._sigmoid(gates[:, : self.hidden_size])
            f = self._sigmoid(
                gates[:, self.hidden_size : 2 * self.hidden_size]
            )
            g = np.tanh(gates[:, 2 * self.hidden_size : 3 * self.hidden_size])
            o = self._sigmoid(gates[:, 3 * self.hidden_size :])
            previous_cell = cell
            cell = f * cell + i * g
            hidden = o * np.tanh(cell)
            if history is not None:
                history.append(
                    (combined, i, f, g, o, cell.copy(), previous_cell.copy())
                )
        output = hidden @ self.Wy + self.by
        if history is not None:
            history.append(hidden.copy())
        return output, history

    def loss_and_gradients(
        self, sequences: np.ndarray, expected: np.ndarray
    ) -> Tuple[float, Dict[str, np.ndarray]]:
        predicted, history = self.forward(sequences, cache=True)
        assert history is not None
        difference = predicted - expected
        loss = float(np.mean(difference * difference))
        d_output = (2.0 / difference.size) * difference
        last_hidden = history[-1]
        gradients = {
            "W": np.zeros_like(self.W),
            "b": np.zeros_like(self.b),
            "Wy": last_hidden.T @ d_output,
            "by": d_output.sum(axis=0),
        }
        d_hidden = d_output @ self.Wy.T
        d_cell = np.zeros_like(d_hidden)
        for state in reversed(history[:-1]):
            combined, i, f, g, o, cell, previous_cell = state
            tanh_cell = np.tanh(cell)
            d_o = d_hidden * tanh_cell
            d_cell = d_cell + d_hidden * o * (1.0 - tanh_cell * tanh_cell)
            d_f = d_cell * previous_cell
            d_i = d_cell * g
            d_g = d_cell * i
            d_previous_cell = d_cell * f
            d_gates = np.concatenate(
                (
                    d_i * i * (1.0 - i),
                    d_f * f * (1.0 - f),
                    d_g * (1.0 - g * g),
                    d_o * o * (1.0 - o),
                ),
                axis=1,
            )
            gradients["W"] += combined.T @ d_gates
            gradients["b"] += d_gates.sum(axis=0)
            d_combined = d_gates @ self.W.T
            d_hidden = d_combined[:, self.input_size :]
            d_cell = d_previous_cell
        return loss, gradients

    def predict(self, sequences: np.ndarray, batch_size: int = 512) -> np.ndarray:
        chunks = []
        for start in range(0, len(sequences), batch_size):
            prediction, _ = self.forward(sequences[start : start + batch_size])
            chunks.append(prediction)
        return (
            np.concatenate(chunks, axis=0)
            if chunks
            else np.empty((0, self.output_size), dtype=np.float32)
        )

    def save(
        self,
        path: os.PathLike[str] | str,
        target_mean: np.ndarray,
        target_scale: np.ndarray,
        sequence_length: int,
    ) -> None:
        np.savez_compressed(
            path,
            architecture=np.asarray("LSTM"),
            W=self.W,
            b=self.b,
            Wy=self.Wy,
            by=self.by,
            input_size=np.asarray(self.input_size),
            hidden_size=np.asarray(self.hidden_size),
            output_size=np.asarray(self.output_size),
            target_mean=np.asarray(target_mean, dtype=np.float32),
            target_scale=np.asarray(target_scale, dtype=np.float32),
            sequence_length=np.asarray(sequence_length),
            target_names=np.asarray(TARGETS),
        )

    @classmethod
    def load(
        cls, path: os.PathLike[str] | str
    ) -> Tuple["LSTMRegressor", np.ndarray, np.ndarray, int]:
        with np.load(path, allow_pickle=False) as data:
            architecture = str(data["architecture"])
            if architecture != "LSTM":
                raise ValueError(
                    f"El artefacto declara {architecture}, no una red LSTM"
                )
            model = cls(
                int(data["input_size"]),
                int(data["hidden_size"]),
                int(data["output_size"]),
            )
            model.W = data["W"].astype(np.float32)
            model.b = data["b"].astype(np.float32)
            model.Wy = data["Wy"].astype(np.float32)
            model.by = data["by"].astype(np.float32)
            target_names = tuple(str(value) for value in data["target_names"])
            if target_names != TARGETS:
                raise ValueError("El artefacto no predice las cuatro ventanas requeridas")
            return (
                model,
                data["target_mean"].astype(np.float32),
                data["target_scale"].astype(np.float32),
                int(data["sequence_length"]),
            )


class Adam:
    def __init__(
        self,
        parameters: Dict[str, np.ndarray],
        learning_rate: float = 1e-3,
    ) -> None:
        self.parameters = parameters
        self.learning_rate = float(learning_rate)
        self.m = {name: np.zeros_like(value) for name, value in parameters.items()}
        self.v = {name: np.zeros_like(value) for name, value in parameters.items()}
        self.step = 0

    def update(
        self, gradients: Dict[str, np.ndarray], clip_norm: float = 5.0
    ) -> None:
        total_norm = math.sqrt(
            sum(float(np.sum(gradient * gradient)) for gradient in gradients.values())
        )
        multiplier = min(1.0, clip_norm / (total_norm + 1e-12))
        self.step += 1
        for name, parameter in self.parameters.items():
            gradient = gradients[name] * multiplier
            self.m[name] = 0.9 * self.m[name] + 0.1 * gradient
            self.v[name] = 0.999 * self.v[name] + 0.001 * (gradient * gradient)
            corrected_m = self.m[name] / (1.0 - 0.9**self.step)
            corrected_v = self.v[name] / (1.0 - 0.999**self.step)
            parameter -= self.learning_rate * corrected_m / (
                np.sqrt(corrected_v) + 1e-8
            )


def train_epochs(
    model: LSTMRegressor,
    train_x: np.ndarray,
    train_y: np.ndarray,
    epochs: int,
    batch_size: int,
    learning_rate: float,
    seed: int,
    validation: Tuple[np.ndarray, np.ndarray] | None = None,
    patience: int | None = None,
) -> Tuple[List[Dict[str, float]], Dict[str, np.ndarray], int]:
    optimizer = Adam(model.parameters, learning_rate)
    rng = np.random.default_rng(seed)
    history: List[Dict[str, float]] = []
    best_state = {name: value.copy() for name, value in model.parameters.items()}
    best_epoch = 1
    best_validation = math.inf
    stale = 0
    for epoch in range(1, epochs + 1):
        order = rng.permutation(len(train_x))
        losses = []
        for start in range(0, len(order), batch_size):
            batch = order[start : start + batch_size]
            loss, gradients = model.loss_and_gradients(train_x[batch], train_y[batch])
            optimizer.update(gradients)
            losses.append(loss)
        record: Dict[str, float] = {
            "epoch": float(epoch),
            "train_mse": float(np.mean(losses)),
        }
        if validation is not None:
            validation_x, validation_y = validation
            validation_prediction = model.predict(validation_x)
            validation_mse = float(
                np.mean((validation_prediction - validation_y) ** 2)
            )
            record["validation_mse"] = validation_mse
            if validation_mse < best_validation - 1e-7:
                best_validation = validation_mse
                best_epoch = epoch
                best_state = {
                    name: value.copy() for name, value in model.parameters.items()
                }
                stale = 0
            else:
                stale += 1
        else:
            best_state = {
                name: value.copy() for name, value in model.parameters.items()
            }
            best_epoch = epoch
        history.append(record)
        if validation is not None and patience and stale >= patience:
            break
    for name, value in best_state.items():
        model.parameters[name][...] = value
    return history, best_state, best_epoch


def target_scaler(targets: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
    mean = targets.mean(axis=0).astype(np.float32)
    scale = targets.std(axis=0).astype(np.float32)
    scale = np.where(scale > 1e-8, scale, 1.0).astype(np.float32)
    return mean, scale


def enforce_count_constraints(prediction: np.ndarray) -> np.ndarray:
    constrained = np.clip(prediction, 0.0, TARGET_LIMITS)
    constrained = np.maximum.accumulate(constrained, axis=1)
    return np.minimum(constrained, TARGET_LIMITS)


def regression_metrics(actual: np.ndarray, prediction: np.ndarray) -> dict:
    result = {}
    for index, target in enumerate(TARGETS):
        difference = prediction[:, index] - actual[:, index]
        mae = float(np.mean(np.abs(difference)))
        rmse = float(np.sqrt(np.mean(difference * difference)))
        denominator = float(
            np.sum((actual[:, index] - actual[:, index].mean()) ** 2)
        )
        r2 = (
            1.0 - float(np.sum(difference * difference)) / denominator
            if denominator > 0
            else 0.0
        )
        rounded = np.rint(prediction[:, index])
        result[target] = {
            "n": int(len(actual)),
            "mae": mae,
            "rmse": rmse,
            "r2": r2,
            "exact_accuracy": float(
                np.mean(rounded == actual[:, index]) * 100.0
            ),
            "within_one_accuracy": float(
                np.mean(np.abs(rounded - actual[:, index]) <= 1.0) * 100.0
            ),
        }
    return result


def write_json(path: os.PathLike[str] | str, payload: dict) -> None:
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
