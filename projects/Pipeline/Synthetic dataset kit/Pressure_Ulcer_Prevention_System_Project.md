# Pressure Ulcer Prevention System

## Overview

The Pressure Ulcer Prevention System is a hardware and software solution
designed to help prevent pressure ulcers (bedsores) in bedridden
patients through continuous posture monitoring, pressure sensing, and
on-device AI prediction.

The project is currently in the **prototype phase** and is designed for
two categories of users:

1.  **Home Care Solution** -- For caregivers and family members caring
    for patients at home.
2.  **Hospital Solution** -- For small and low-cost hospitals requiring
    centralized patient monitoring.

------------------------------------------------------------------------

# Target Users

## Home Care

Features: - Mobile application - Real-time alerts - Easy installation -
Affordable deployment

## Hospital

Features: - Centralized monitoring dashboard - Multiple patient
monitoring - Real-time risk visualization - Staff notifications -
Cost-effective deployment

------------------------------------------------------------------------

# System Architecture

The complete system consists of two hardware modules.

## Module 1 -- Smart Belt

The Smart Belt is worn around the patient's waist.

### Hardware

-   Silicon Labs EFR32xG26 Development Board
-   Built-in IMU (Accelerometer)
-   Bluetooth Low Energy (BLE)
-   Integrated AI accelerator for Edge AI

### Responsibilities

The Smart Belt continuously identifies the patient's posture:

-   Left Side
-   Supine (Middle)
-   Right Side

If the patient remains in the same posture for a predefined duration,
the Smart Belt requests additional pressure information from the Smart
Bedsheet.

The Smart Belt acts as the master controller and performs all Edge AI
inference locally.

------------------------------------------------------------------------

## Module 2 -- Smart Bedsheet

The Smart Bedsheet consists of **four movable sensing plates**.

Each sensing plate contains Force Sensitive Resistor (FSR) sensors.

### Design Features

-   Plates are detachable.
-   Plates can be repositioned according to patient size.
-   Wires can be disconnected and reconnected after repositioning.
-   The design is adaptable for different body sizes.

### Responsibilities

The Smart Bedsheet measures:

-   Pressure distribution
-   Weight concentration
-   Body movement

The bedsheet normally remains idle and only transmits pressure data when
requested by the Smart Belt via Bluetooth Low Energy (BLE).

The Smart Bedsheet is built around an ESP32 microcontroller.

------------------------------------------------------------------------

# Communication Flow

1.  The Smart Belt continuously monitors body posture using the IMU.
2.  If the patient stays in the same posture beyond a predefined time,
    the Smart Belt requests pressure data from the Smart Bedsheet.
3.  The ESP32 collects readings from the FSR sensing plates.
4.  The FSR readings are transmitted to the EFR32 board over BLE.
5.  The EFR32 performs Edge AI inference locally.
6.  The predicted pressure ulcer risk is sent back to the ESP32.
7.  The ESP32 transmits the prediction to:
    -   Mobile application (Home Care)
    -   Hospital Dashboard (Hospital Solution)

> **Current Prototype Communication**
>
> For the prototype version, communication between the ESP32 and both
> the mobile application and hospital dashboard is performed using **UDP
> (User Datagram Protocol)** over Wi-Fi for lightweight, low-latency
> data transfer.
>
> This communication method is temporary and may be replaced with a more
> secure and scalable protocol (such as MQTT, HTTPS, or WebSockets) in
> future versions.

------------------------------------------------------------------------

# Edge AI Prediction

The AI model executes entirely on the Silicon Labs EFR32xG26.

The prediction is based on three primary factors:

1.  Patient Position
    -   Left
    -   Right
    -   Supine
2.  Time
    -   Duration spent continuously in the same posture.
3.  FSR Sensor Data
    -   Pressure readings collected from the four sensing plates.

Additional engineered features extracted from these sensor values are
also used to improve prediction performance.

The model outputs a **Pressure Ulcer Risk Score**, indicating whether
the patient is at Low, Medium, or High risk of developing a pressure
ulcer.

------------------------------------------------------------------------

# Final Outputs

## Home Care

-   Mobile application
-   Real-time notifications
-   Reposition reminders

## Hospital

-   Centralized dashboard
-   Multi-patient monitoring
-   High-risk patient highlighting
-   Caregiver notifications

------------------------------------------------------------------------

# Key Advantages

-   Edge AI for low-latency prediction
-   No cloud dependency for inference
-   Affordable hardware
-   Adjustable sensing plates
-   BLE communication between hardware modules
-   Wi-Fi connectivity for remote monitoring
-   Temporary UDP communication with the application and dashboard
    during the prototype phase
-   Scalable architecture for both home and hospital deployments

------------------------------------------------------------------------

# Future Improvements

-   Replace UDP with a production-ready communication protocol.
-   Increase the number of sensing plates for higher pressure mapping
    resolution.
-   Add historical analytics and patient trend visualization.
-   Integrate cloud synchronization for long-term data storage.
-   Support predictive recommendations for caregiver reposition
    schedules.
