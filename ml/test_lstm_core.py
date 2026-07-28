#!/usr/bin/env python3

import tempfile
import unittest
from pathlib import Path
import sys

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from lstm_core import (
    METADATA_COLUMNS,
    NUMERIC_COLUMNS,
    TARGETS,
    LSTMRegressor,
    Preprocessor,
    build_sequences,
    enforce_count_constraints,
    train_epochs,
)


class LSTMPipelineTests(unittest.TestCase):
    def setUp(self):
        self.rows = []
        for index in range(40):
            row = {
                column: str(index + feature_index / 100)
                for feature_index, column in enumerate(NUMERIC_COLUMNS)
            }
            row.update(
                {
                    "ghost_type": "high" if index % 2 else "low",
                    "relocation": "appearance" if index % 5 == 0 else "move",
                    "event_timestamp": str(1_000 + index * 60),
                    "event_date": "2026-05-01",
                    "event_hour": "10",
                    "event_minute": str(index % 60),
                }
            )
            self.rows.append(row)
        self.rows[3][NUMERIC_COLUMNS[7]] = ""

    def test_preprocessor_persists_exact_transform(self):
        scaler = Preprocessor.fit(self.rows[:30])
        expected = scaler.transform(self.rows)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "scaler.npz"
            scaler.save(path)
            reloaded = Preprocessor.load(path)
            actual = reloaded.transform(self.rows)
        np.testing.assert_allclose(actual, expected, rtol=0, atol=0)
        self.assertEqual(expected.shape[1], 66)
        self.assertTrue(
            set(METADATA_COLUMNS).isdisjoint(Preprocessor.model_feature_names())
        )

    def test_lstm_trains_four_outputs_and_reloads_weights(self):
        rng = np.random.default_rng(7)
        features = rng.normal(size=(50, 6)).astype(np.float32)
        targets = np.stack(
            (
                np.maximum(features[:, 0], 0),
                np.maximum(features[:, 0], 0) + 0.2,
                np.maximum(features[:, 0], 0) + 0.5,
                np.maximum(features[:, 0], 0) + 0.8,
            ),
            axis=1,
        ).astype(np.float32)
        sequences, sequence_targets, _ = build_sequences(
            features, targets, range(50), 4
        )
        self.assertIsNotNone(sequence_targets)
        model = LSTMRegressor(6, 5, len(TARGETS), seed=3)
        before = np.mean((model.predict(sequences) - sequence_targets) ** 2)
        train_epochs(
            model,
            sequences,
            sequence_targets,
            epochs=10,
            batch_size=16,
            learning_rate=0.01,
            seed=3,
        )
        after = np.mean((model.predict(sequences) - sequence_targets) ** 2)
        self.assertLess(after, before)

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "model.npz"
            mean = np.zeros(4, dtype=np.float32)
            scale = np.ones(4, dtype=np.float32)
            model.save(path, mean, scale, 4)
            reloaded, actual_mean, actual_scale, sequence_length = (
                LSTMRegressor.load(path)
            )
        np.testing.assert_allclose(
            reloaded.predict(sequences), model.predict(sequences), rtol=0, atol=0
        )
        np.testing.assert_array_equal(actual_mean, mean)
        np.testing.assert_array_equal(actual_scale, scale)
        self.assertEqual(sequence_length, 4)

    def test_count_constraints_are_valid(self):
        raw = np.asarray([[4, -1, 12, 2]], dtype=np.float32)
        constrained = enforce_count_constraints(raw)
        self.assertTrue(np.all(constrained >= 0))
        self.assertTrue(np.all(constrained <= np.asarray([3, 5, 10, 15])))
        self.assertTrue(np.all(np.diff(constrained, axis=1) >= 0))


if __name__ == "__main__":
    unittest.main()
