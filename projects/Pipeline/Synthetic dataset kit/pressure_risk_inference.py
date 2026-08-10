#!/usr/bin/env python3
"""Inference helper for the prototype four-zone pressure-time risk model."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np
import torch
from torch import nn

MODEL_PATH = Path('/mnt/data/pressure_risk_mlp_v2.pt')
METADATA_PATH = Path('/mnt/data/pressure_risk_model_metadata_v2.json')
ZONES = ['head', 'shoulders', 'hips', 'heels']
POSITIONS = ['CENTER', 'LEFT', 'RIGHT']


class PressureRiskMLP(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.network = nn.Sequential(
            nn.Linear(12, 16),
            nn.ReLU(),
            nn.Linear(16, 8),
            nn.ReLU(),
            nn.Linear(8, 4),
            nn.Sigmoid(),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.network(x)


def classify(score: float, low_medium: float, medium_high: float) -> str:
    if score < low_medium:
        return 'LOW'
    if score < medium_high:
        return 'MEDIUM'
    return 'HIGH'


class PressureRiskPredictor:
    def __init__(self, model_path: Path = MODEL_PATH, metadata_path: Path = METADATA_PATH):
        self.meta = json.loads(metadata_path.read_text(encoding='utf-8'))
        self.model = PressureRiskMLP()
        self.model.load_state_dict(torch.load(model_path, map_location='cpu', weights_only=True))
        self.model.eval()

    def _adc_to_load(self, adc: np.ndarray) -> np.ndarray:
        q05 = np.array([self.meta['calibration'][z]['adc_q05'] for z in ZONES], dtype=np.float32)
        q95 = np.array([self.meta['calibration'][z]['adc_q95'] for z in ZONES], dtype=np.float32)
        if self.meta['adc_decreases_with_load']:
            load = (q95 - adc) / np.maximum(q95 - q05, 1.0)
        else:
            load = (adc - q05) / np.maximum(q95 - q05, 1.0)
        return np.clip(load, 0.0, 1.0)

    def predict(self, position: str, duration_sec: float, adc_values: list[float]) -> dict:
        position = position.upper()
        if position not in POSITIONS:
            raise ValueError(f'position must be one of {POSITIONS}')
        if duration_sec < 0:
            raise ValueError('duration_sec must be non-negative')
        if len(adc_values) != 4:
            raise ValueError('adc_values must contain head, shoulders, hips, heels')

        adc = np.asarray(adc_values, dtype=np.float32)
        loads = self._adc_to_load(adc)
        teacher = self.meta['teacher_config']
        effective = np.clip(
            (loads - teacher['relief_floor']) / (1.0 - teacher['relief_floor']),
            0.0,
            1.0,
        )
        exposure = (
            np.power(effective, teacher['pressure_exponent'])
            * duration_sec
            / teacher['reference_duration_seconds']
        )
        exposure_scaled = np.clip(exposure, 0.0, 3.0) / 3.0

        position_one_hot = np.array([1.0 if position == p else 0.0 for p in POSITIONS], dtype=np.float32)
        duration_feature = np.array(
            [math.log1p(duration_sec) / math.log1p(6.0 * 60.0 * 60.0)],
            dtype=np.float32,
        )
        features = np.concatenate([position_one_hot, duration_feature, loads, exposure_scaled])

        with torch.no_grad():
            scores = self.model(torch.from_numpy(features[None, :])).numpy()[0] * 100.0

        low_medium = teacher['low_medium_threshold']
        medium_high = teacher['medium_high_threshold']
        per_zone = {
            zone: {
                'adc': float(adc[i]),
                'normalized_load': float(loads[i]),
                'risk_score': float(scores[i]),
                'risk_level': classify(float(scores[i]), low_medium, medium_high),
            }
            for i, zone in enumerate(ZONES)
        }
        highest_idx = int(np.argmax(scores))
        return {
            'position': position,
            'same_position_duration_sec': float(duration_sec),
            'zones': per_zone,
            'highest_risk_body_part': ZONES[highest_idx],
            'highest_risk_score': float(scores[highest_idx]),
            'highest_risk_level': classify(float(scores[highest_idx]), low_medium, medium_high),
            'warning': self.meta['warning'],
        }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--position', required=True, choices=POSITIONS)
    parser.add_argument('--duration-sec', required=True, type=float)
    parser.add_argument('--head', required=True, type=float)
    parser.add_argument('--shoulders', required=True, type=float)
    parser.add_argument('--hips', required=True, type=float)
    parser.add_argument('--heels', required=True, type=float)
    args = parser.parse_args()

    predictor = PressureRiskPredictor()
    result = predictor.predict(
        args.position,
        args.duration_sec,
        [args.head, args.shoulders, args.hips, args.heels],
    )
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
