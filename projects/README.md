# VitalSense Projects

This directory contains the two main components of the VitalSense system:

## vitalsense-app

**VitalSense Caregiver Dashboard (Flutter Mobile App)**

A real-time caregiver dashboard mobile application built with Flutter. It listens for UDP JSON broadcasts from the VitalSense ESP32 gateway to continuously monitor bedridden patient posture, pressure sensor (FSR) arrays, and ML-inferred pressure injury risk across critical anatomical regions.

- **Tech Stack**: Flutter 3.x, Dart 3.x
- **Platform**: Android (APK)
- **Communication**: UDP Protocol v1 on port 5005
- **Key Features**:
  - Auto-discovery & zero-config networking
  - Bed & connection status monitoring (LIVE/STALE/OFFLINE)
  - Posture & duration tracking (CENTER/BACK, LEFT, RIGHT)
  - Pressure injury risk assessment (4 anatomical zones)
  - Raw sensor & plate ADC data visualization
  - Engineering & diagnostics view

## vitalsense-dashboard

**VitalSense Web Dashboard (Python/Flask)**

A web-based dashboard for monitoring and managing VitalSense devices. Provides a comprehensive interface for real-time patient monitoring, device management, and data visualization.

- **Tech Stack**: Python, Flask, JavaScript (Frontend)
- **Architecture**: Backend API + Frontend UI
- **Key Components**:
  - `app.py` - Main Flask application entry point
  - `backend/` - Backend API services
  - `frontend/` - Frontend static assets
  - `core/` - Core business logic
  - `ui/` - User interface components
  - `assets/` - Static assets

---

## Project Structure

```
projects/
├── vitalsense-app/          # Flutter mobile app
│   ├── lib/                 # Dart source code
│   ├── android/             # Android platform files
│   ├── pubspec.yaml         # Flutter dependencies
│   └── README.md            # App-specific documentation
│
└── vitalsense-dashboard/    # Python web dashboard
    ├── app.py               # Main Flask application
    ├── backend/             # Backend services
    ├── frontend/            # Frontend assets
    ├── core/                # Core logic
    ├── ui/                  # UI components
    └── assets/              # Static assets
```

## Getting Started

Each project has its own setup instructions. Please refer to the individual README files in each project directory for detailed installation and usage guides.

- [vitalsense-app Setup](./vitalsense-app/README.md)
- [vitalsense-dashboard Setup](./vitalsense-dashboard/README.md)