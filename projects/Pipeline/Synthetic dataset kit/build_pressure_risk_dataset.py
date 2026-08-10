#!/usr/bin/env python3
"""
Build a synthetic, time-dependent pressure-risk dataset from paired 60 Hz
Smart Belt and Smart Bedsheet recordings, then train a compact four-output MLP.

IMPORTANT:
- The generated target is a synthetic engineering risk index, not a clinically
  validated probability of pressure-ulcer development.
- Higher ADC is assumed to mean greater FSR loading: values near 4095
  indicate heavy load and values near 0 indicate light or no load.
"""

from __future__ import annotations

import json
import math
import random
from dataclasses import dataclass, asdict
from pathlib import Path

import numpy as np
import pandas as pd
import torch
from torch import nn
from torch.utils.data import DataLoader, TensorDataset


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

BED_CSV = Path("/mnt/data/vitalsense_data_20260807_020412.csv")
BELT_CSV = Path("/mnt/data/xg26_position_dataset3.csv")
OUTPUT_CSV = Path("/mnt/data/synthetic_pressure_ulcer_risk_dataset.csv")
MODEL_PATH = Path("/mnt/data/pressure_risk_mlp_v2.pt")
METADATA_PATH = Path("/mnt/data/pressure_risk_model_metadata_v2.json")

SEED = 42
N_SYNTHETIC_SUBJECTS = 120
ROWS_PER_SUBJECT = 500
ADC_DECREASES_WITH_LOAD = False
STABLE_SEGMENT_MIN_SECONDS = 300
STABLE_MARGIN_SECONDS = 20

ZONE_NAMES = ["head", "shoulders", "hips", "heels"]
RAW_ZONE_COLUMNS = [f"{z}_average" for z in ZONE_NAMES]
POSITIONS = ["CENTER", "LEFT", "RIGHT"]


@dataclass
class TeacherConfig:
    # Prototype anchor only. It is not a universal clinical threshold.
    reference_duration_seconds: float = 2.0 * 60.0 * 60.0
    relief_floor: float = 0.10
    pressure_exponent: float = 1.50
    risk_gain: float = 1.50
    low_medium_threshold: float = 35.0
    medium_high_threshold: float = 70.0


TEACHER = TeacherConfig()


def set_seed(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)


def majority(series: pd.Series) -> str:
    return str(series.mode().iat[0])


def load_from_adc(adc: np.ndarray, q05: np.ndarray, q95: np.ndarray) -> np.ndarray:
    """Convert raw ADC values to a dataset-relative 0..1 contact-load index."""
    denom = np.maximum(q95 - q05, 1.0)
    if ADC_DECREASES_WITH_LOAD:
        load = (q95 - adc) / denom
    else:
        load = (adc - q05) / denom
    return np.clip(load, 0.0, 1.0)


def adc_from_load(load: np.ndarray, q05: np.ndarray, q95: np.ndarray) -> np.ndarray:
    """Convert normalized contact load back to plausible synthetic ADC values."""
    if ADC_DECREASES_WITH_LOAD:
        adc = q95 - load * (q95 - q05)
    else:
        adc = q05 + load * (q95 - q05)
    return adc


def teacher_risk(load: np.ndarray, duration_seconds: np.ndarray) -> np.ndarray:
    """
    Synthetic pressure-time risk teacher.

    Risk grows nonlinearly with contact load and continuously with uninterrupted
    exposure duration. The output is an engineering risk index from 0 to 100.
    """
    effective = np.clip(
        (load - TEACHER.relief_floor) / (1.0 - TEACHER.relief_floor), 0.0, 1.0
    )
    dose = (
        np.power(effective, TEACHER.pressure_exponent)
        * duration_seconds[..., None]
        / TEACHER.reference_duration_seconds
    )
    risk = 100.0 * (1.0 - np.exp(-TEACHER.risk_gain * dose))
    return np.clip(risk, 0.0, 100.0)


def risk_level(score: float) -> str:
    if score < TEACHER.low_medium_threshold:
        return "LOW"
    if score < TEACHER.medium_high_threshold:
        return "MEDIUM"
    return "HIGH"


def load_and_align() -> tuple[pd.DataFrame, dict[str, dict[str, float]]]:
    bed = pd.read_csv(BED_CSV)
    belt = pd.read_csv(BELT_CSV)

    bed["computer_timestamp"] = pd.to_datetime(bed["computer_timestamp"])
    bed["time_sec"] = (
        bed["computer_timestamp"] - bed["computer_timestamp"].iloc[0]
    ).dt.total_seconds()
    bed["sec"] = np.floor(bed["time_sec"]).astype(int)
    belt["sec"] = np.floor(belt["time_sec"]).astype(int)

    bed_1s = bed.groupby("sec", as_index=False)[RAW_ZONE_COLUMNS].mean()
    belt_1s = belt.groupby("sec", as_index=False).agg(position=("position", majority))
    aligned = bed_1s.merge(belt_1s, on="sec", how="inner")

    # Identify long stable posture segments and remove transition margins.
    aligned["segment_id"] = aligned["position"].ne(aligned["position"].shift()).cumsum()
    seg = aligned.groupby("segment_id").agg(
        segment_length=("sec", "size"),
        segment_start=("sec", "min"),
        segment_end=("sec", "max"),
        position=("position", "first"),
    )
    aligned = aligned.merge(seg, left_on="segment_id", right_index=True, suffixes=("", "_seg"))
    stable = aligned[
        (aligned["segment_length"] >= STABLE_SEGMENT_MIN_SECONDS)
        & (aligned["sec"] >= aligned["segment_start"] + STABLE_MARGIN_SECONDS)
        & (aligned["sec"] <= aligned["segment_end"] - STABLE_MARGIN_SECONDS)
    ].copy()

    q05 = bed[RAW_ZONE_COLUMNS].quantile(0.05).to_numpy(dtype=float)
    q95 = bed[RAW_ZONE_COLUMNS].quantile(0.95).to_numpy(dtype=float)
    stable_load = load_from_adc(stable[RAW_ZONE_COLUMNS].to_numpy(dtype=float), q05, q95)
    for idx, zone in enumerate(ZONE_NAMES):
        stable[f"{zone}_load"] = stable_load[:, idx]

    calibration = {
        zone: {"adc_q05": float(q05[i]), "adc_q95": float(q95[i])}
        for i, zone in enumerate(ZONE_NAMES)
    }
    return stable, calibration


def sample_duration_seconds(rng: np.random.Generator, n: int) -> np.ndarray:
    """Stratify duration so short, medium, long, and very long exposure are covered."""
    bands = rng.integers(0, 4, size=n)
    bounds_minutes = np.array([[0, 30], [30, 90], [90, 180], [180, 360]], dtype=float)
    low = bounds_minutes[bands, 0]
    high = bounds_minutes[bands, 1]
    return rng.uniform(low, high) * 60.0


def generate_synthetic(stable: pd.DataFrame, calibration: dict[str, dict[str, float]]) -> pd.DataFrame:
    rng = np.random.default_rng(SEED)
    banks = {p: stable[stable["position"] == p].reset_index(drop=True) for p in POSITIONS}
    for p, bank in banks.items():
        if bank.empty:
            raise RuntimeError(f"No stable source rows found for posture {p}")

    q05 = np.array([calibration[z]["adc_q05"] for z in ZONE_NAMES], dtype=float)
    q95 = np.array([calibration[z]["adc_q95"] for z in ZONE_NAMES], dtype=float)

    records: list[dict[str, object]] = []
    for subject_id in range(N_SYNTHETIC_SUBJECTS):
        # These modify sensor/contact expression, not hidden biological risk.
        subject_global = float(rng.lognormal(mean=0.0, sigma=0.10))
        subject_zone = rng.lognormal(mean=0.0, sigma=0.08, size=4)
        mattress_factor = float(rng.uniform(0.90, 1.10))

        positions = rng.choice(POSITIONS, size=ROWS_PER_SUBJECT, replace=True)
        durations = sample_duration_seconds(rng, ROWS_PER_SUBJECT)

        for row_idx, (position, duration_sec) in enumerate(zip(positions, durations)):
            bank = banks[str(position)]
            source = bank.iloc[int(rng.integers(0, len(bank)))]
            base_load = source[[f"{z}_load" for z in ZONE_NAMES]].to_numpy(dtype=float)

            # Preserve the empirical posture pattern while creating plausible
            # subject, mattress, placement, drift, and measurement variation.
            slow_drift = rng.normal(0.0, 0.025, size=4)
            sample_noise = rng.normal(0.0, 0.020, size=4)
            synthetic_load = np.clip(
                base_load * subject_global * subject_zone * mattress_factor
                + slow_drift
                + sample_noise,
                0.0,
                1.0,
            )

            synthetic_adc = adc_from_load(synthetic_load, q05, q95)
            synthetic_adc += rng.normal(0.0, 5.0, size=4)
            synthetic_adc = np.clip(synthetic_adc, 0.0, 4095.0)

            risks = teacher_risk(synthetic_load[None, :], np.array([duration_sec]))[0]
            highest_idx = int(np.argmax(risks))
            highest_score = float(risks[highest_idx])

            rec: dict[str, object] = {
                "synthetic_subject_id": subject_id,
                "sample_id": subject_id * ROWS_PER_SUBJECT + row_idx,
                "position": str(position),
                "same_position_duration_sec": float(duration_sec),
                "same_position_duration_min": float(duration_sec / 60.0),
            }
            for i, zone in enumerate(ZONE_NAMES):
                rec[f"{zone}_adc"] = float(synthetic_adc[i])
                rec[f"{zone}_load"] = float(synthetic_load[i])
                rec[f"{zone}_risk_score"] = float(risks[i])
                rec[f"{zone}_risk_level"] = risk_level(float(risks[i]))
            rec["highest_risk_body_part"] = ZONE_NAMES[highest_idx]
            rec["highest_risk_score"] = highest_score
            rec["highest_risk_level"] = risk_level(highest_score)
            records.append(rec)

    return pd.DataFrame.from_records(records)


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


def make_features(df: pd.DataFrame) -> np.ndarray:
    position_one_hot = pd.get_dummies(df["position"])[POSITIONS].to_numpy(dtype=np.float32)
    duration_feature = (
        np.log1p(df["same_position_duration_sec"].to_numpy(dtype=np.float32))
        / math.log1p(6.0 * 60.0 * 60.0)
    )[:, None]
    loads = df[[f"{z}_load" for z in ZONE_NAMES]].to_numpy(dtype=np.float32)
    duration_seconds = df["same_position_duration_sec"].to_numpy(dtype=np.float32)[:, None]
    effective = np.clip(
        (loads - TEACHER.relief_floor) / (1.0 - TEACHER.relief_floor), 0.0, 1.0
    )
    exposure = (
        np.power(effective, TEACHER.pressure_exponent)
        * duration_seconds
        / TEACHER.reference_duration_seconds
    )
    exposure_scaled = np.clip(exposure, 0.0, 3.0) / 3.0
    return np.concatenate(
        [position_one_hot, duration_feature, loads, exposure_scaled], axis=1
    )


def train_model(df: pd.DataFrame) -> dict[str, float]:
    train_mask = df["synthetic_subject_id"] < int(N_SYNTHETIC_SUBJECTS * 0.8)
    train_df = df[train_mask].copy()
    test_df = df[~train_mask].copy()

    x_train = torch.from_numpy(make_features(train_df))
    y_train = torch.from_numpy(
        train_df[[f"{z}_risk_score" for z in ZONE_NAMES]]
        .to_numpy(dtype=np.float32) / 100.0
    )
    x_test = torch.from_numpy(make_features(test_df))
    y_test = torch.from_numpy(
        test_df[[f"{z}_risk_score" for z in ZONE_NAMES]]
        .to_numpy(dtype=np.float32) / 100.0
    )

    model = PressureRiskMLP()
    optimizer = torch.optim.Adam(model.parameters(), lr=1e-2)
    loss_fn = nn.MSELoss()

    # The model is tiny, so full-batch training is faster and deterministic.
    model.train()
    for _epoch in range(1200):
        optimizer.zero_grad(set_to_none=True)
        pred = model(x_train)
        loss = loss_fn(pred, y_train)
        loss.backward()
        optimizer.step()

    model.eval()
    with torch.no_grad():
        pred = model(x_test)

    abs_error = torch.abs(pred - y_test)
    mae = float(abs_error.mean().item() * 100.0)
    rmse = float(torch.sqrt(((pred - y_test) ** 2).mean()).item() * 100.0)
    max_abs = float(abs_error.max().item() * 100.0)
    body_part_accuracy = float(
        (pred.argmax(dim=1) == y_test.argmax(dim=1)).float().mean().item()
    )
    true_max = y_test.max(dim=1).values
    pred_max = pred.max(dim=1).values
    true_level = torch.where(
        true_max < 0.35, 0, torch.where(true_max < 0.70, 1, 2)
    )
    pred_level = torch.where(
        pred_max < 0.35, 0, torch.where(pred_max < 0.70, 1, 2)
    )
    level_accuracy = float((true_level == pred_level).float().mean().item())

    torch.save(model.state_dict(), MODEL_PATH)
    return {
        "test_mae_risk_points": mae,
        "test_rmse_risk_points": rmse,
        "test_max_abs_error_risk_points": max_abs,
        "highest_risk_body_part_accuracy": body_part_accuracy,
        "highest_risk_level_accuracy": level_accuracy,
        "train_subjects": int(train_df["synthetic_subject_id"].nunique()),
        "test_subjects": int(test_df["synthetic_subject_id"].nunique()),
        "train_rows": int(len(train_df)),
        "test_rows": int(len(test_df)),
    }


def main() -> None:
    set_seed(SEED)
    stable, calibration = load_and_align()
    # Always regenerate because pressure polarity and source calibration are
    # part of the dataset definition. Reusing an older CSV could silently
    # preserve an incorrect ADC-to-load direction.
    synthetic = generate_synthetic(stable, calibration)
    synthetic.to_csv(OUTPUT_CSV, index=False)
    metrics = train_model(synthetic)

    posture_load_means = (
        stable.groupby("position")[[f"{z}_load" for z in ZONE_NAMES]]
        .mean()
        .round(6)
        .to_dict(orient="index")
    )

    metadata = {
        "purpose": "Prototype body-part pressure-time risk ranking",
        "warning": (
            "Synthetic engineering risk index only; not a clinically validated "
            "pressure-ulcer probability or diagnostic model."
        ),
        "source_files": [str(BED_CSV), str(BELT_CSV)],
        "source_stable_rows_1s": int(len(stable)),
        "synthetic_rows": int(len(synthetic)),
        "adc_decreases_with_load": ADC_DECREASES_WITH_LOAD,
        "positions": POSITIONS,
        "zones": ZONE_NAMES,
        "calibration": calibration,
        "teacher_config": asdict(TEACHER),
        "posture_load_means_from_recording": posture_load_means,
        "model": {
            "type": "PyTorch MLP",
            "input_order": [
                "position_CENTER",
                "position_LEFT",
                "position_RIGHT",
                "log_duration_normalized",
                "head_load",
                "shoulders_load",
                "hips_load",
                "heels_load",
                "head_exposure_scaled",
                "shoulders_exposure_scaled",
                "hips_exposure_scaled",
                "heels_exposure_scaled",
            ],
            "architecture": "12 -> 16 ReLU -> 8 ReLU -> 4 Sigmoid",
            "output_order": [f"{z}_risk_score_0_to_1" for z in ZONE_NAMES],
            "parameter_count": sum(p.numel() for p in PressureRiskMLP().parameters()),
            "metrics": metrics,
        },
    }
    METADATA_PATH.write_text(json.dumps(metadata, indent=2), encoding="utf-8")

    print(json.dumps(metadata, indent=2))
    print(f"Saved: {OUTPUT_CSV}")
    print(f"Saved: {MODEL_PATH}")
    print(f"Saved: {METADATA_PATH}")


if __name__ == "__main__":
    main()
