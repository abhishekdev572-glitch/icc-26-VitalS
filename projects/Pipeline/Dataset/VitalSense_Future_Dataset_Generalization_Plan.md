# VitalSense Future Dataset Collection Plan
## Generalizing FSR Calibration and Pressure-Risk Model Across People

**Document purpose:** Define how future VitalSense datasets should be collected so that FSR calibration and the pressure-risk model generalize across different people, body regions, postures, sessions, and hardware variation.

---

# 1. Goal

The current model and calibration were developed using data from a limited subject set.

Future data collection should make the system more robust across:

- different body weights
- different heights
- different body compositions
- different age groups
- different body shapes
- different pressure distributions
- different mattress conditions
- different clothing conditions
- different sensor placements
- different sensor units
- repeated sessions on different days
- CENTER, LEFT, and RIGHT positions
- Head, Shoulders, Hips, and Heels loading

The objective is not only to collect more rows.

The objective is to collect **more independent human and hardware variation**.

---

# 2. Main Generalization Problem

An FSR ADC value does not necessarily mean exactly the same thing for every person.

Example:

```text
Subject A
Head average = 3800

Subject B
Head average = 3100
```

Both may represent significant pressure depending on:

- body weight
- head position
- contact area
- pillow/mattress
- sensor placement
- sensor tolerance
- body geometry

Therefore the future model should learn from a population rather than a single-person calibration range.

---

# 3. Dataset Design Principle

The dataset must be organized around:

```text
SUBJECT
  -> SESSION
      -> POSTURE
          -> BODY REGION
              -> TIME
                  -> SENSOR VALUES
```

The most important unit of independence is the **subject**.

Do not randomly mix rows from the same subject across training and testing.

---

# 4. Recommended Subject Count

For early engineering validation:

```text
Minimum useful pilot:
20–30 subjects
```

Better development dataset:

```text
50–100 subjects
```

Stronger generalization study:

```text
100+ subjects
```

The exact sample size should later be decided based on validation targets and intended claims.

---

# 5. Subject Diversity

Try to deliberately include subjects across different ranges.

Recommended metadata:

```text
subject_id
age
sex
height_cm
weight_kg
BMI
```

Optional:

```text
body_fat_percent
shoulder_width_cm
hip_width_cm
waist_circumference_cm
```

Do not store personally identifying information in the ML dataset unless genuinely required.

Use anonymous IDs such as:

```text
SUBJ_001
SUBJ_002
SUBJ_003
```

---

# 6. Suggested Weight Distribution

Avoid collecting data mostly from one weight band.

Try to include approximately:

```text
< 50 kg
50–60 kg
60–70 kg
70–80 kg
80–90 kg
90–100 kg
> 100 kg
```

The exact distribution can depend on the intended user population.

---

# 7. Suggested Height Distribution

Try to include:

```text
< 155 cm
155–165 cm
165–175 cm
175–185 cm
> 185 cm
```

---

# 8. Sessions Per Subject

Do not collect only one continuous session per person.

Recommended:

```text
2–3 sessions per subject
```

Preferably on:

```text
different days
```

This helps capture:

- sensor repositioning
- posture variation
- natural day-to-day variation
- clothing variation
- setup variation

---

# 9. Required Postures

Every subject should ideally contribute data for:

```text
CENTER
LEFT
RIGHT
```

If later more postures are added, use explicit new labels instead of reusing existing ones.

---

# 10. Required Body Regions

Collect and analyze:

```text
Head
Shoulders
Hips
Heels
```

FSR mapping:

```text
FSR0 + FSR1 -> Head
FSR2 + FSR3 -> Shoulders
FSR4 + FSR5 -> Hips
FSR6 + FSR7 -> Heels
```

---

# 11. Raw Sensor Data Must Always Be Saved

Do not save only plate averages.

Always store:

```text
fsr0
fsr1
fsr2
fsr3
fsr4
fsr5
fsr6
fsr7
```

Then also calculate:

```text
head_avg
shoulders_avg
hips_avg
heels_avg
```

This allows future:

- recalibration
- sensor fault detection
- asymmetric-pressure analysis
- better feature engineering

---

# 12. Recommended Core Row Format

Each row should contain at least:

```text
timestamp_ms
subject_id
session_id

position
position_duration_sec

fsr0
fsr1
fsr2
fsr3
fsr4
fsr5
fsr6
fsr7

head_avg
shoulders_avg
hips_avg
heels_avg

weight_kg
height_cm
BMI

mattress_id
sensor_mat_id
```

---

# 13. Recommended Extended Row Format

Suggested CSV columns:

```csv
timestamp_ms,
subject_id,
session_id,
trial_id,
position,
position_duration_sec,
fsr0,
fsr1,
fsr2,
fsr3,
fsr4,
fsr5,
fsr6,
fsr7,
head_avg,
shoulders_avg,
hips_avg,
heels_avg,
age,
sex,
height_cm,
weight_kg,
bmi,
mattress_id,
mattress_type,
clothing_condition,
sensor_mat_id,
sensor_layout_version,
firmware_version,
notes
```

---

# 14. Data Sampling Frequency

For raw dataset collection, save data at a higher rate than the ML inference rate.

Recommended:

```text
10–60 Hz raw acquisition
```

If storage is a concern:

```text
10 Hz
```

is already much better than only saving one sample per second.

The model may still run at 1 Hz later.

---

# 15. Keep Raw and Derived Datasets Separate

Recommended structure:

```text
raw/
processed/
features/
splits/
models/
reports/
```

Example:

```text
dataset_v2/
├── raw/
├── processed/
├── features/
├── metadata/
├── splits/
├── models/
└── reports/
```

Do not overwrite raw sensor data after processing.

---

# 16. Trial Structure

A useful collection trial could be:

```text
1. Subject enters setup
2. Record subject metadata
3. Confirm sensor mat placement
4. Record no-load baseline
5. Subject lies CENTER
6. Collect CENTER data
7. Subject turns LEFT
8. Collect LEFT data
9. Subject turns RIGHT
10. Collect RIGHT data
11. Repeat selected posture trials
12. End session
```

---

# 17. No-Load Baseline

Before each subject session, collect:

```text
30–60 seconds
```

with no person on the mat.

Save all 8 raw FSR values.

This provides:

```text
sensor baseline
noise level
offset
drift
```

---

# 18. Loaded Calibration Data

For each body region, capture:

```text
light load
medium load
high load
```

where practical.

Do not hard-code ADC ranges before observing the population.

The aim is to learn the distribution.

---

# 19. Natural Lying Data

Artificial pressing is useful for engineering calibration, but it should not be the only source.

Also collect data with subjects naturally lying in:

```text
CENTER
LEFT
RIGHT
```

because natural body contact differs from manually pressing individual sensors.

---

# 20. Pressure Duration Coverage

The model uses duration, so the dataset should include short and long uninterrupted exposure.

Recommended duration bands:

```text
0–1 min
1–5 min
5–15 min
15–30 min
30–60 min
60–120 min
120+ min
```

For practical data collection, long-duration trials may need a staged study.

Do not train a long-duration risk model using only short-duration data.

---

# 21. Capture Position Changes

The dataset should contain:

```text
CENTER -> LEFT
LEFT -> CENTER
CENTER -> RIGHT
RIGHT -> CENTER
LEFT -> RIGHT
RIGHT -> LEFT
```

Record:

```text
position_before
position_after
transition_time
```

This helps validate:

- duration reset
- posture classification
- transient FSR behavior

---

# 22. Sensor Placement Variation

Collect sessions with realistic small placement variation.

Examples:

```text
mat shifted slightly left
mat shifted slightly right
mat shifted slightly upward
mat shifted slightly downward
```

Do not intentionally create unsafe or unrealistic configurations.

The aim is to capture normal installation variability.

---

# 23. Mattress Variation

If VitalSense may be used on more than one mattress type, record:

```text
mattress_id
mattress_type
mattress_thickness
firmness_category
```

Different mattresses can change how force reaches the FSRs.

---

# 24. Clothing Variation

Useful labels:

```text
light clothing
normal clothing
thick clothing
blanket present
```

Only include conditions expected in real deployment.

---

# 25. Hardware Variation

Do not train only using one physical sensor mat.

Recommended:

```text
at least 3–5 sensor mats
```

for development if possible.

Track:

```text
sensor_mat_id
sensor_batch
sensor_layout_version
ESP32 hardware revision
```

This helps distinguish:

```text
human variation
```

from:

```text
sensor-to-sensor variation
```

---

# 26. Sensor Calibration Measurements

For each physical sensor mat, record:

```text
no-load baseline
known test loads if available
maximum practical response
noise
repeatability
```

This can later support sensor-specific normalization.

---

# 27. Per-Region Population Statistics

After data collection, calculate for each region:

```text
minimum
maximum
mean
median
standard deviation
q01
q05
q10
q25
q50
q75
q90
q95
q99
```

For:

```text
Head
Shoulders
Hips
Heels
```

Do this:

```text
overall
by subject
by posture
by weight band
by mattress
by sensor mat
```

---

# 28. Do Not Immediately Use One Global q05/q95

The current model uses region calibration ranges.

For future generalization, compare several approaches:

```text
A. global per-region normalization

B. subject-normalized load

C. sensor-mat-normalized load

D. baseline-corrected load

E. percentile-based normalization

F. learned normalization
```

Evaluate which approach performs best on unseen subjects.

---

# 29. Baseline-Corrected Feature

One useful candidate feature is:

```text
corrected_adc =
raw_adc - no_load_baseline
```

Then normalize:

```text
normalized_load =
corrected_adc / expected_loaded_range
```

This can reduce sensitivity to sensor offset.

---

# 30. Pair Asymmetry Feature

Because each region uses two FSR sensors, add:

```text
pair_difference =
abs(sensor_A - sensor_B)
```

Example:

```text
head_asymmetry =
abs(fsr0 - fsr1)
```

This may help detect:

- partial contact
- incorrect placement
- uneven loading

---

# 31. Recommended Derived Features

Candidate features:

```text
position one-hot encoding
log(position_duration_sec)

head_load
shoulders_load
hips_load
heels_load

head_exposure
shoulders_exposure
hips_exposure
heels_exposure

head_asymmetry
shoulders_asymmetry
hips_asymmetry
heels_asymmetry

total_load

regional_load_fraction

movement/change features
```

Do not add every feature blindly.

Validate whether each improves generalization.

---

# 32. Regional Load Fraction

Potential feature:

```text
head_fraction =
head_avg / total_plate_load
```

Likewise:

```text
shoulders_fraction
hips_fraction
heels_fraction
```

This may help the model understand how pressure is distributed across the body.

---

# 33. Subject Metadata as Model Input

Do not automatically use:

```text
age
sex
weight
height
BMI
```

as model inputs.

First evaluate whether they materially improve performance.

They are valuable as analysis variables even if they are not used by the final model.

---

# 34. Train / Validation / Test Split

This is critical.

Split by:

```text
subject_id
```

Not by rows.

Recommended:

```text
70% subjects -> training
15% subjects -> validation
15% subjects -> test
```

Example:

```text
SUBJ_001
```

must appear in only one split.

---

# 35. Why Row-Level Random Split Is Wrong

If rows are randomly split:

```text
same subject
same mattress
same sensors
same session
```

may appear in both train and test.

This can artificially inflate accuracy.

The test set must represent:

```text
people the model has never seen
```

---

# 36. Stronger Validation

Also consider:

```text
Leave-One-Subject-Out cross-validation
```

or:

```text
Grouped K-Fold by subject
```

This is especially useful while the dataset is still relatively small.

---

# 37. Hardware Holdout Test

For stronger validation, reserve at least one sensor mat that is never used for training.

Then test:

```text
new person
+
new sensor mat
```

This is a better approximation of production deployment.

---

# 38. Mattress Holdout Test

If multiple mattress types are intended:

```text
train on mattress types A/B
test on mattress type C
```

This measures environmental generalization.

---

# 39. Data Quality Checks

Automatically flag rows where:

```text
ADC < 0
ADC > 4095
missing sensor values
duplicate timestamps
invalid position
negative duration
impossible duration jump
sensor stuck at constant value
```

---

# 40. Sensor-Stuck Detection

Potential QC rule:

```text
same exact ADC value
for abnormally long duration
```

may indicate:

```text
sensor disconnection
ADC issue
MUX issue
wiring fault
```

Do not delete automatically without inspection.

---

# 41. Saturation Tracking

Track how often each sensor reaches:

```text
4095
```

A high saturation rate may indicate:

```text
insufficient dynamic range
```

and may affect model quality.

---

# 42. Near-Zero Tracking

Also track how often each sensor remains around:

```text
0–10
```

while that body region is expected to be loaded.

This may indicate:

```text
placement issue
broken sensor
incorrect mapping
```

---

# 43. Session Metadata File

Keep a separate metadata file.

Example:

```csv
subject_id,session_id,date,weight_kg,height_cm,bmi,mattress_id,sensor_mat_id,notes
SUBJ_001,S001,2026-08-10,72,174,23.8,MAT_A,FSRMAT_01,normal session
```

---

# 44. Trial Metadata

Example:

```csv
trial_id,session_id,position,start_time,end_time,notes
T001,S001,CENTER,...
T002,S001,LEFT,...
T003,S001,RIGHT,...
```

---

# 45. Dataset Versioning

Use explicit versions:

```text
VitalSense_Dataset_v1
VitalSense_Dataset_v2
VitalSense_Dataset_v3
```

Each version should record:

```text
subjects
sessions
hardware versions
firmware versions
collection dates
processing script version
feature version
model version
```

---

# 46. Never Modify Old Dataset Versions

Do not silently replace:

```text
dataset_v2
```

with corrected files.

Create:

```text
dataset_v2_1
```

or:

```text
dataset_v3
```

with documented changes.

---

# 47. Recommended Folder Structure

```text
VitalSense_Dataset_v2/
│
├── README.md
│
├── raw/
│   ├── SUBJ_001/
│   ├── SUBJ_002/
│   └── ...
│
├── metadata/
│   ├── subjects.csv
│   ├── sessions.csv
│   ├── trials.csv
│   ├── sensor_mats.csv
│   └── mattresses.csv
│
├── processed/
│
├── features/
│
├── splits/
│   ├── train_subjects.txt
│   ├── validation_subjects.txt
│   └── test_subjects.txt
│
├── calibration/
│
├── reports/
│
└── models/
```

---

# 48. Recommended Raw Filename

Example:

```text
SUBJ_001_S001_CENTER_T001.csv
```

or:

```text
SUBJ_001/
    S001/
        CENTER_T001.csv
        LEFT_T002.csv
        RIGHT_T003.csv
```

---

# 49. Ground-Truth Labels

Pressure-risk labels should not be invented from ADC values alone.

If using a synthetic or engineering teacher model, explicitly label it:

```text
engineering_teacher_risk
```

Do not call it:

```text
clinical_ground_truth
```

unless clinical validation actually exists.

---

# 50. Clinical Data

If future clinical validation is planned, maintain clinical labels separately from synthetic labels.

Example:

```text
synthetic_risk_score
clinical_outcome
expert_assessment
```

Do not merge them into one ambiguous target column.

---

# 51. Current Risk Thresholds

If engineering thresholds such as:

```text
LOW
MEDIUM
HIGH
```

are used during development, record the exact threshold version in the dataset/model metadata.

Do not assume thresholds will remain unchanged forever.

---

# 52. Recalibration Analysis

After collecting the larger dataset:

```text
Step 1
Plot all raw FSR distributions.

Step 2
Plot per-body-region distributions.

Step 3
Compare subjects.

Step 4
Compare weight groups.

Step 5
Compare sensor mats.

Step 6
Compare mattresses.

Step 7
Choose normalization strategy.

Step 8
Retrain model.

Step 9
Test only on unseen subjects.

Step 10
Run hardware holdout validation.
```

---

# 53. Important Visualizations

Generate:

```text
histogram of ADC per region
boxplot per subject
boxplot per weight band
boxplot per posture
boxplot per sensor mat
ADC versus body weight
ADC versus BMI
risk versus duration
risk versus regional load
sensor A versus sensor B
```

---

# 54. Generalization Metrics

Do not evaluate only overall MAE.

Track:

```text
MAE
RMSE
R²
highest-risk zone accuracy
risk-level accuracy
```

Also calculate them by:

```text
subject
weight band
posture
body region
sensor mat
mattress
```

---

# 55. Worst-Group Performance

The final model should not only perform well on average.

Check the worst-performing subgroup.

Example:

```text
overall MAE = 2.0

but

>100 kg group MAE = 8.5
```

That would indicate poor generalization.

---

# 56. Per-Body-Region Evaluation

Always report separately:

```text
Head
Shoulders
Hips
Heels
```

because one region may generalize poorly even when aggregate metrics look good.

---

# 57. Posture-Specific Evaluation

Evaluate separately:

```text
CENTER
LEFT
RIGHT
```

The model should not be considered generalized if it works only in CENTER.

---

# 58. Duration-Specific Evaluation

Evaluate:

```text
short exposure
medium exposure
long exposure
```

because duration is a major model input.

---

# 59. Data Leakage Prevention

Do not derive normalization statistics from the full dataset before splitting.

Correct process:

```text
split subjects
    ↓
fit normalization on TRAIN only
    ↓
apply same normalization to validation/test
```

This prevents test information from leaking into training.

---

# 60. Calibration Leakage Prevention

If q05/q95 values are used:

```text
calculate q05/q95 from training subjects only
```

Then apply those fixed values to validation and test subjects.

---

# 61. Model Selection

Use:

```text
validation subjects
```

for:

```text
architecture selection
feature selection
threshold tuning
hyperparameter tuning
```

Use the final test subjects only once the model design is frozen.

---

# 62. Final Test Set

Do not repeatedly tune using the test set.

Otherwise it becomes another validation set.

Keep one final untouched population for final evaluation.

---

# 63. Recommended Collection Checklist

Before each session:

```text
[ ] Correct subject ID
[ ] Correct session ID
[ ] Weight recorded
[ ] Height recorded
[ ] Mattress ID recorded
[ ] Sensor mat ID recorded
[ ] Firmware version recorded
[ ] No-load baseline captured
[ ] MUX mapping verified
[ ] All 8 FSRs responding
[ ] IMU calibration completed
```

---

# 64. During Session Checklist

```text
[ ] CENTER trial collected
[ ] LEFT trial collected
[ ] RIGHT trial collected
[ ] Position transitions captured
[ ] Sensor readings monitored
[ ] Saturation noted
[ ] Sensor dropout noted
[ ] Unusual movement noted
[ ] Trial notes saved
```

---

# 65. After Session Checklist

```text
[ ] Raw files copied
[ ] Files not manually edited
[ ] Metadata complete
[ ] Subject/session mapping correct
[ ] QC script run
[ ] Backup created
```

---

# 66. Recommended Initial Target for Next Dataset

A practical next milestone:

```text
30 subjects
x
3 positions
x
2 sessions
```

gives:

```text
180 subject-position sessions
```

before considering repeated trials.

This would already be much stronger than a single-person calibration dataset.

---

# 67. Better Next Milestone

A stronger target:

```text
50 subjects
x
3 positions
x
2 sessions
```

gives:

```text
300 subject-position sessions
```

This can provide a useful foundation for evaluating population-level calibration.

---

# 68. Suggested Development Phases

## Phase 1 — Sensor characterization

```text
5–10 subjects
multiple pressure levels
all 8 FSRs
all 4 body regions
```

Goal:

```text
understand physical sensor response
```

---

## Phase 2 — Population calibration

```text
20–30 subjects
CENTER/LEFT/RIGHT
multiple sessions
```

Goal:

```text
derive robust normalization strategy
```

---

## Phase 3 — Model generalization

```text
50+ subjects
subject-wise train/validation/test
```

Goal:

```text
retrain and validate unseen-person performance
```

---

## Phase 4 — Deployment robustness

Include:

```text
multiple sensor mats
multiple mattresses
different clothing
different days
```

Goal:

```text
production robustness
```

---

# 69. What Must Be Frozen Before Final Model Training

Freeze and document:

```text
FSR mapping
sensor hardware revision
MUX hardware revision
ADC resolution
sampling logic
filtering
plate averaging
position labels
normalization method
duration feature
risk target generation
train/validation/test subject split
```

---

# 70. Final Model Acceptance Questions

Before calling the model generalized, answer:

```text
Does it work on people never seen during training?

Does it work across different body weights?

Does it work across CENTER, LEFT, RIGHT?

Does it work across Head, Shoulders, Hips, Heels?

Does it work with different sensor mats?

Does it remain stable across sessions/days?

Does it work on intended mattresses?

Does performance remain acceptable in the worst subgroup?
```

If any answer is unknown, generalization is not yet established.

---

# 71. Recommended Output of the Future Study

The future dataset effort should produce:

```text
1. Raw multi-subject FSR dataset

2. Subject/session metadata

3. Sensor-mat metadata

4. Population ADC distributions

5. Per-region calibration analysis

6. Train/validation/test subject split

7. Generalized preprocessing configuration

8. Retrained model

9. Generalization report

10. Final firmware calibration constants/model
```

---

# 72. Short Reference

```text
COLLECT
-------
8 raw FSRs
4 plate averages
position
position duration
subject metadata
session metadata
hardware metadata

DIVERSIFY
---------
weight
height
body composition
posture
mattress
sensor mat
session/day

SPLIT
-----
BY SUBJECT
not by row

CALIBRATE
---------
using TRAIN subjects only

VALIDATE
--------
on unseen subjects

TEST
----
new subjects
preferably new sensor hardware too

DO NOT
------
assume one person's ADC calibration is universal
```

---

# 73. Core Principle

The future VitalSense dataset should be designed so that:

```text
the model learns the relationship between
body position + pressure distribution + exposure duration
```

rather than learning:

```text
the specific ADC behavior of one person,
one session,
one mattress,
or one physical sensor mat.
```

That is the central requirement for generalization.

---

**End of VitalSense Future Dataset Collection Plan**
