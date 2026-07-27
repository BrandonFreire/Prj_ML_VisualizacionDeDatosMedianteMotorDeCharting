#!/usr/bin/env python3
"""Pipeline reproducible de datos para los targets GhostsInSwings.

El único fit se hace con train_features.csv. Test se transforma desde el
preprocesador recargado desde scaler.joblib, por lo que no puede ajustar sus
parámetros con datos de julio.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
from sklearn.compose import ColumnTransformer
from sklearn.impute import SimpleImputer
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, RobustScaler, StandardScaler

TARGETS = ["Y_3m", "Y_5m", "Y_10m", "Y_15m"]
METADATA = [
    "event_id", "event_timestamp", "event_date", "event_hour", "event_minute",
    "event_index", "ghost_index", "complete",
]


def args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Preprocesa CSV de features sin leakage.")
    parser.add_argument("--train", type=Path, default="train_features.csv")
    parser.add_argument("--test", type=Path, default="test_features.csv")
    parser.add_argument("--output-dir", type=Path, default="artifacts/preprocessed")
    parser.add_argument("--scaler", choices=("standard", "robust"), default="standard")
    return parser.parse_args()


def read_csv(path: Path) -> pd.DataFrame:
    if not path.is_file():
        raise FileNotFoundError(f"Archivo no encontrado: {path}")
    frame = pd.read_csv(path)
    missing = [name for name in TARGETS if name not in frame.columns]
    if missing:
        raise ValueError(f"{path} no contiene targets: {missing}")
    if frame.empty:
        raise ValueError(f"{path} está vacío")
    return frame


def onehot() -> OneHotEncoder:
    try:
        return OneHotEncoder(handle_unknown="ignore", sparse_output=False)
    except TypeError:  # Compatibilidad con sklearn < 1.2
        return OneHotEncoder(handle_unknown="ignore", sparse=False)


def target_frame(frame: pd.DataFrame) -> pd.DataFrame:
    return frame[TARGETS].apply(pd.to_numeric, errors="coerce").replace([np.inf, -np.inf], np.nan)


def feature_layout(train: pd.DataFrame) -> tuple[list[str], list[str], list[str]]:
    candidates = [name for name in train.columns if name not in set(TARGETS + METADATA)]
    numeric = [name for name in candidates if pd.api.types.is_numeric_dtype(train[name])]
    categorical = [name for name in candidates if name not in numeric]
    missing_only = [
        name for name in candidates
        if train[name].replace([np.inf, -np.inf], np.nan).notna().sum() == 0
    ]
    numeric = [name for name in numeric if name not in missing_only]
    categorical = [name for name in categorical if name not in missing_only]
    if not numeric and not categorical:
        raise ValueError("No hay features utilizables después de limpiar columnas vacías.")
    return numeric, categorical, missing_only


def x_frame(frame: pd.DataFrame, numeric: list[str], categorical: list[str]) -> pd.DataFrame:
    # El reindex garantiza mismo orden y permite tratar una columna ausente de
    # test como missing, sin recalcular/descubrir features en test.
    out = frame.reindex(columns=numeric + categorical).copy()
    if numeric:
        out[numeric] = out[numeric].replace([np.inf, -np.inf], np.nan)
    return out


def preprocessor(numeric: list[str], categorical: list[str], scaler_kind: str) -> ColumnTransformer:
    scale = StandardScaler() if scaler_kind == "standard" else RobustScaler()
    parts = []
    if numeric:
        parts.append(("numeric", Pipeline([
            ("imputer", SimpleImputer(strategy="median")),
            ("scaler", scale),
        ]), numeric))
    if categorical:
        parts.append(("categorical", Pipeline([
            ("imputer", SimpleImputer(strategy="most_frequent")),
            ("onehot", onehot()),
        ]), categorical))
    return ColumnTransformer(parts, remainder="drop", sparse_threshold=0.0)


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1 << 20), b""):
            value.update(block)
    return value.hexdigest()


def names(transformer: ColumnTransformer) -> list[str]:
    try:
        return list(transformer.get_feature_names_out())
    except AttributeError:
        result: list[str] = []
        for name, transform, columns in transformer.transformers_:
            if name == "numeric":
                result.extend(f"numeric__{col}" for col in columns)
            elif name == "categorical":
                result.extend(f"categorical__{col}" for col in transform.named_steps["onehot"].get_feature_names(columns))
        return result


def save_npz(path: Path, x: np.ndarray, y: np.ndarray, feature_names: list[str], target_ready: np.ndarray) -> None:
    np.savez_compressed(
        path,
        X=np.asarray(x, dtype=np.float32),
        Y=np.asarray(y, dtype=np.float32),
        feature_names=np.asarray(feature_names, dtype=str),
        target_names=np.asarray(TARGETS, dtype=str),
        target_available=np.asarray(target_ready, dtype=bool),
    )


def numeric_report(transformer: ColumnTransformer, train_x: pd.DataFrame, numeric: list[str]) -> dict:
    if not numeric:
        return {"numeric_features": 0}
    values = transformer.named_transformers_["numeric"].transform(train_x[numeric])
    mean = np.mean(values, axis=0)
    std = np.std(values, axis=0, ddof=0)
    nonconstant = std > 1e-12
    return {
        "numeric_features": len(numeric),
        "train_abs_mean_max": float(np.max(np.abs(mean))),
        "train_std_min_nonconstant": float(np.min(std[nonconstant])) if np.any(nonconstant) else 0.0,
        "train_std_max_nonconstant": float(np.max(std[nonconstant])) if np.any(nonconstant) else 0.0,
        "constant_numeric_features": int(len(std) - np.count_nonzero(nonconstant)),
    }


def main() -> None:
    config = args()
    train_raw, test_raw = read_csv(config.train), read_csv(config.test)
    numeric, categorical, dropped = feature_layout(train_raw)
    train_y_all, test_y = target_frame(train_raw), target_frame(test_raw)
    ready_train = train_y_all.notna().all(axis=1).to_numpy()
    ready_test = test_y.notna().all(axis=1).to_numpy()
    if not ready_train.any():
        raise ValueError("Ninguna fila de train tiene los cuatro targets completos.")

    train_x = x_frame(train_raw, numeric, categorical).loc[ready_train].reset_index(drop=True)
    test_x = x_frame(test_raw, numeric, categorical)
    train_y = train_y_all.loc[ready_train].reset_index(drop=True)
    train_meta = train_raw.reindex(columns=[c for c in METADATA if c in train_raw]).loc[ready_train].reset_index(drop=True)
    test_meta = test_raw.reindex(columns=[c for c in METADATA if c in test_raw]).reset_index(drop=True)

    fitted = preprocessor(numeric, categorical, config.scaler)
    # Único fit_transform del programa: entrenamiento etiquetado completo.
    x_train = np.asarray(fitted.fit_transform(train_x), dtype=np.float64)

    config.output_dir.mkdir(parents=True, exist_ok=True)
    bundle_path = config.output_dir / "scaler.joblib"
    bundle = {
        "preprocessor": fitted,
        "numeric_columns": numeric,
        "categorical_columns": categorical,
        "dropped_all_missing_columns": dropped,
        "target_columns": TARGETS,
        "fit_dataset": str(config.train),
        "fit_dataset_sha256": digest(config.train),
        "scaler_kind": config.scaler,
    }
    joblib.dump(bundle, bundle_path)

    # Prueba operativa de reutilización: test se procesa desde el bundle ya
    # persistido; no se invoca fit ni fit_transform sobre la data de julio.
    persisted = joblib.load(bundle_path)
    x_test = np.asarray(persisted["preprocessor"].transform(test_x), dtype=np.float64)
    feature_names = names(persisted["preprocessor"])

    save_npz(config.output_dir / "train_preprocessed.npz", x_train, train_y.to_numpy(), feature_names, np.ones(len(train_y), dtype=bool))
    save_npz(config.output_dir / "test_preprocessed.npz", x_test, test_y.to_numpy(), feature_names, ready_test)
    train_meta.to_csv(config.output_dir / "train_metadata.csv", index=False)
    test_meta.to_csv(config.output_dir / "test_metadata.csv", index=False)

    report = {
        "leakage_guard": {
            "fit_performed_only_on": str(config.train),
            "train_sha256": bundle["fit_dataset_sha256"],
            "test_operation": "transform_only_from_reloaded_scaler.joblib",
            "metadata_excluded_from_X": [c for c in METADATA if c in train_raw],
            "targets_never_imputed": True,
        },
        "rows": {
            "train_input": int(len(train_raw)),
            "train_complete_targets": int(len(train_y)),
            "train_dropped_incomplete_targets": int(len(train_raw) - len(train_y)),
            "test_input": int(len(test_raw)),
            "test_complete_targets": int(ready_test.sum()),
            "test_pending_targets": int(len(test_raw) - ready_test.sum()),
        },
        "features": {
            "numeric_input": len(numeric), "categorical_input": len(categorical),
            "model_output_dimension": int(x_train.shape[1]),
            "dropped_all_missing_columns": dropped,
        },
        "scaling": {"kind": config.scaler, **numeric_report(fitted, train_x, numeric)},
    }
    (config.output_dir / "preprocessing_report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    (config.output_dir / "feature_schema.json").write_text(json.dumps({
        "model_feature_names": feature_names,
        "numeric_columns": numeric,
        "categorical_columns": categorical,
        "targets": TARGETS,
        "metadata_not_in_X": report["leakage_guard"]["metadata_excluded_from_X"],
    }, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(report, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
