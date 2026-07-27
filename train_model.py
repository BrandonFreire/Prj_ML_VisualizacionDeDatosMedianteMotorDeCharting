#!/usr/bin/env python3
"""Entrena una GRU multi-output para los cuatro targets GhostsInSwings.

Cada ejemplo es una ventana temporal de eventos de fantasma. No hay CNN: la
GRU recibe secuencias (batch, sequence_length, n_features) y predice los cuatro
horizontes del último evento de cada ventana.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import random
from dataclasses import asdict, dataclass
from pathlib import Path

import numpy as np
import torch
from torch import Tensor, nn
from torch.utils.data import DataLoader, TensorDataset


TARGET_NAMES = ("Y_3m", "Y_5m", "Y_10m", "Y_15m")


@dataclass
class ModelConfig:
    input_size: int
    hidden_size: int = 96
    num_layers: int = 2
    dropout: float = 0.20
    output_size: int = 4


class GhostGRURegressor(nn.Module):
    """GRU unidireccional seguida de una pequeña cabeza de regresión."""

    def __init__(self, config: ModelConfig) -> None:
        super().__init__()
        self.gru = nn.GRU(
            input_size=config.input_size,
            hidden_size=config.hidden_size,
            num_layers=config.num_layers,
            batch_first=True,
            dropout=config.dropout if config.num_layers > 1 else 0.0,
        )
        self.head = nn.Sequential(
            nn.LayerNorm(config.hidden_size),
            nn.Dropout(config.dropout),
            nn.Linear(config.hidden_size, config.hidden_size // 2),
            nn.ReLU(),
            nn.Dropout(config.dropout),
            nn.Linear(config.hidden_size // 2, config.output_size),
        )

    def forward(self, values: Tensor) -> Tensor:
        _, hidden = self.gru(values)
        return self.head(hidden[-1])


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Entrenamiento GRU sin CNN para targets GhostsInSwings.")
    parser.add_argument("--train", type=Path, default="artifacts/preprocessed/train_preprocessed.npz")
    parser.add_argument("--output-dir", type=Path, default="artifacts/models")
    parser.add_argument("--sequence-length", type=int, default=16)
    parser.add_argument("--hidden-size", type=int, default=96)
    parser.add_argument("--layers", type=int, default=2)
    parser.add_argument("--dropout", type=float, default=0.20)
    parser.add_argument("--learning-rate", type=float, default=1e-3)
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--epochs", type=int, default=150)
    parser.add_argument("--patience", type=int, default=20)
    parser.add_argument("--validation-fraction", type=float, default=0.20)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--device", choices=("auto", "cpu", "cuda"), default="auto")
    return parser.parse_args()


def set_seed(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)


def load_dataset(path: Path) -> tuple[np.ndarray, np.ndarray, list[str]]:
    if not path.is_file():
        raise FileNotFoundError(f"No existe el dataset: {path}")
    data = np.load(path)
    x = np.asarray(data["X"], dtype=np.float32)
    y = np.asarray(data["Y"], dtype=np.float32)
    available = np.asarray(data.get("target_available", np.ones(len(y), dtype=bool)), dtype=bool)
    names = [str(value) for value in data.get("target_names", np.asarray(TARGET_NAMES))]
    if x.ndim != 2 or y.ndim != 2 or y.shape[1] != 4 or len(x) != len(y):
        raise ValueError("NPZ inválido: se esperaba X=(N,F) e Y=(N,4).")
    valid = available & np.isfinite(x).all(axis=1) & np.isfinite(y).all(axis=1)
    x, y = x[valid], y[valid]
    if len(x) < 2:
        raise ValueError("No hay suficientes filas completas para entrenar.")
    return x, y, names


def make_sequences(x: np.ndarray, y: np.ndarray, length: int) -> tuple[np.ndarray, np.ndarray]:
    if length < 1:
        raise ValueError("--sequence-length debe ser >= 1")
    if len(x) < length:
        raise ValueError(f"Se requieren al menos {length} filas, disponibles: {len(x)}")
    windows = np.stack([x[start:start + length] for start in range(len(x) - length + 1)])
    # El target corresponde al último evento, nunca a una fila futura.
    return windows, y[length - 1:]


def metrics(y_true: np.ndarray, y_pred: np.ndarray, names: list[str]) -> dict[str, dict[str, float]]:
    result: dict[str, dict[str, float]] = {}
    for index, name in enumerate(names):
        actual, predicted = y_true[:, index], y_pred[:, index]
        error = predicted - actual
        ss_res = float(np.square(error).sum())
        ss_tot = float(np.square(actual - actual.mean()).sum())
        result[name] = {
            "mae": float(np.abs(error).mean()),
            "rmse": float(math.sqrt(np.square(error).mean())),
            "r2": float(1.0 - ss_res / ss_tot) if ss_tot > 0 else float("nan"),
        }
    return result


@torch.no_grad()
def predict(model: nn.Module, loader: DataLoader, device: torch.device) -> tuple[np.ndarray, np.ndarray]:
    model.eval()
    predictions, actuals = [], []
    for features, targets in loader:
        predictions.append(model(features.to(device)).cpu().numpy())
        actuals.append(targets.numpy())
    return np.concatenate(actuals), np.concatenate(predictions)


def run_epoch(model: nn.Module, loader: DataLoader, optimizer: torch.optim.Optimizer | None, device: torch.device) -> float:
    training = optimizer is not None
    model.train(training)
    criterion = nn.MSELoss()
    total, count = 0.0, 0
    for features, targets in loader:
        features, targets = features.to(device), targets.to(device)
        if training:
            optimizer.zero_grad(set_to_none=True)
        outputs = model(features)
        loss = criterion(outputs, targets)
        if training:
            loss.backward()
            nn.utils.clip_grad_norm_(model.parameters(), max_norm=1.0)
            optimizer.step()
        total += loss.item() * len(features)
        count += len(features)
    return total / max(count, 1)


def write_loss_svg(history: list[dict[str, float]], path: Path) -> None:
    """Curva portable sin añadir matplotlib como dependencia del proyecto."""
    if not history:
        return
    width, height, margin = 760, 360, 48
    values = [point[key] for point in history for key in ("train_mse", "validation_mse")]
    low, high = min(values), max(values)
    high = low + 1.0 if high <= low else high

    def point(index: int, value: float) -> str:
        x = margin + (width - 2 * margin) * index / max(len(history) - 1, 1)
        y = height - margin - (height - 2 * margin) * (value - low) / (high - low)
        return f"{x:.2f},{y:.2f}"

    train = " ".join(point(index, item["train_mse"]) for index, item in enumerate(history))
    valid = " ".join(point(index, item["validation_mse"]) for index, item in enumerate(history))
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">
<rect width="100%" height="100%" fill="#ffffff"/><text x="{margin}" y="25" font-family="sans-serif" font-size="16">MSE: entrenamiento vs validación</text>
<line x1="{margin}" y1="{height-margin}" x2="{width-margin}" y2="{height-margin}" stroke="#333"/><line x1="{margin}" y1="{margin}" x2="{margin}" y2="{height-margin}" stroke="#333"/>
<polyline fill="none" stroke="#1f77b4" stroke-width="2" points="{train}"/><polyline fill="none" stroke="#d62728" stroke-width="2" points="{valid}"/>
<text x="{width-210}" y="30" fill="#1f77b4" font-family="sans-serif" font-size="12">azul: entrenamiento</text><text x="{width-210}" y="47" fill="#d62728" font-family="sans-serif" font-size="12">rojo: validación</text>
<text x="5" y="{margin+5}" font-family="sans-serif" font-size="11">{high:.4f}</text><text x="5" y="{height-margin}" font-family="sans-serif" font-size="11">{low:.4f}</text>
</svg>'''
    path.write_text(svg, encoding="utf-8")


def main() -> None:
    options = parse_args()
    if not 0 < options.validation_fraction < 0.5:
        raise ValueError("--validation-fraction debe estar entre 0 y 0.5")
    set_seed(options.seed)
    x, y, target_names = load_dataset(options.train)
    sequences, targets = make_sequences(x, y, options.sequence_length)
    validation_start = int(len(sequences) * (1 - options.validation_fraction))
    if validation_start < 1 or len(sequences) - validation_start < 1:
        raise ValueError("La división temporal no deja train/validation suficientes.")
    # División cronológica, sin aleatorizar: validación es el tramo posterior.
    x_train, y_train = sequences[:validation_start], targets[:validation_start]
    x_valid, y_valid = sequences[validation_start:], targets[validation_start:]

    device = torch.device("cuda" if options.device == "auto" and torch.cuda.is_available() else options.device)
    if device.type == "cuda" and not torch.cuda.is_available():
        raise RuntimeError("Se solicitó CUDA pero PyTorch no detecta una GPU disponible.")
    config = ModelConfig(x.shape[1], options.hidden_size, options.layers, options.dropout)
    model = GhostGRURegressor(config).to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=options.learning_rate, weight_decay=1e-4)
    scheduler = torch.optim.lr_scheduler.ReduceLROnPlateau(optimizer, mode="min", factor=0.5, patience=7)
    train_loader = DataLoader(TensorDataset(torch.from_numpy(x_train), torch.from_numpy(y_train)), batch_size=options.batch_size, shuffle=True)
    valid_loader = DataLoader(TensorDataset(torch.from_numpy(x_valid), torch.from_numpy(y_valid)), batch_size=options.batch_size, shuffle=False)

    options.output_dir.mkdir(parents=True, exist_ok=True)
    best_path = options.output_dir / "trained_model.pt"
    history: list[dict[str, float]] = []
    best_loss, patience_left = float("inf"), options.patience
    print(f"GRU | input={config.input_size} | sequence={options.sequence_length} | outputs=4 | params={sum(p.numel() for p in model.parameters()):,}")
    print(f"Train sequences={len(x_train):,}; validation sequences={len(x_valid):,}; device={device}")

    for epoch in range(1, options.epochs + 1):
        train_loss = run_epoch(model, train_loader, optimizer, device)
        validation_loss = run_epoch(model, valid_loader, None, device)
        scheduler.step(validation_loss)
        record = {"epoch": epoch, "train_mse": train_loss, "validation_mse": validation_loss, "learning_rate": optimizer.param_groups[0]["lr"]}
        history.append(record)
        print(f"epoch={epoch:03d} train_mse={train_loss:.6f} val_mse={validation_loss:.6f} lr={record['learning_rate']:.2e}")
        if validation_loss < best_loss - 1e-8:
            best_loss, patience_left = validation_loss, options.patience
            torch.save({
                "model_state_dict": model.state_dict(), "model_config": asdict(config),
                "sequence_length": options.sequence_length, "target_names": target_names,
                "feature_count": x.shape[1], "best_validation_mse": best_loss,
            }, best_path)
        else:
            patience_left -= 1
            if patience_left <= 0:
                print("Early stopping: no mejoró validation MSE.")
                break

    checkpoint = torch.load(best_path, map_location=device, weights_only=True)
    model.load_state_dict(checkpoint["model_state_dict"])
    valid_true, valid_pred = predict(model, valid_loader, device)
    report = {
        "architecture": "GRU recurrente sin capas convolucionales",
        "model_config": checkpoint["model_config"],
        "sequence_length": options.sequence_length,
        "best_validation_mse": best_loss,
        "validation_metrics": metrics(valid_true, valid_pred, target_names),
        "training_rows": int(len(y_train)), "validation_rows": int(len(y_valid)),
        "history": history,
    }
    with (options.output_dir / "training_report.json").open("w", encoding="utf-8") as destination:
        json.dump(report, destination, indent=2, ensure_ascii=False)
    with (options.output_dir / "loss_history.csv").open("w", newline="", encoding="utf-8") as destination:
        writer = csv.DictWriter(destination, fieldnames=["epoch", "train_mse", "validation_mse", "learning_rate"])
        writer.writeheader(); writer.writerows(history)
    write_loss_svg(history, options.output_dir / "loss_curve.svg")
    print("\nValidation metrics:")
    for name, values in report["validation_metrics"].items():
        print(f"{name}: MAE={values['mae']:.4f} RMSE={values['rmse']:.4f} R2={values['r2']:.4f}")
    print(f"Model saved: {best_path}")


if __name__ == "__main__":
    main()
