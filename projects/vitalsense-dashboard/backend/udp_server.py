"""
udp_server.py
--------------------------------------------------------------------------
Raspberry Pi bridge for VitalS / UlcerGuard.

Listens for UDP JSON packets sent by the ESP32-C3 belt(s), decodes them,
and re-broadcasts them to every connected React dashboard client as a
Socket.IO "patientData" event.

    ESP32-C3  --UDP-->  udp_server.py (this file)  --Socket.IO-->  React dashboard

Run with:
    python3 udp_server.py

Install dependencies with:
    pip install flask "flask-socketio>=5.3.6" "python-socketio>=5.10.0" "python-engineio>=4.8.0"

=== Why the dashboard was never updating (root causes fixed below) ===

  BUG #1 — Blocking UDP loop sharing a thread with the Socket.IO server.
    If sock.recvfrom() and socketio.run() run in the same thread, one
    starves the other: either the dashboard's Socket.IO handshake never
    completes, or incoming UDP packets are never read promptly (or both).
    Fix: the UDP loop runs in its own background thread, started BEFORE
    socketio.run() is called on the main thread.

  BUG #2 — Emitting the raw UDP bytes/string instead of a parsed dict.
    socketio.emit("patientData", packet) JSON-encodes whatever Python
    object you give it. If `packet` here is still the raw decoded UDP
    string (e.g. missed a json.loads() call), the frontend receives a
    JSON *string*, not an object — so packet.bed is undefined in
    JavaScript, the frontend's own "unknown packet" guard silently
    returns, and nothing ever updates, with no visible error anywhere.
    Fix: json.loads() the UDP payload into a real dict before emitting.

  BUG #3 (config) — cors_allowed_origins missing, or wrong host/port.
    Without cors_allowed_origins="*", browsers block the Socket.IO
    handshake before "connect" ever fires. Without host="0.0.0.0", the
    server only accepts connections from localhost — unreachable from
    the ESP32's/dashboard's actual network. Both are fixed below.

  BUG #4 (config) — using app.run() instead of socketio.run(app, ...).
    Plain Flask/Werkzeug does not understand the Socket.IO/Engine.IO
    protocol at all; clients can open an HTTP connection to it, but the
    Socket.IO handshake never completes. Fixed below.

  BUG #5 — packet["lastUpdated"] trusted from the ESP32 device itself.
    Confirmed from real traffic: the ESP32 is sending its own uptime
    counter as "lastUpdated" (4171, 4172, 4173, ... incrementing by 1
    each packet) — NOT seconds-since-epoch. The frontend does
    `packet.lastUpdated * 1000` assuming Unix epoch seconds, which turns
    "4171" into a JS timestamp of ~1970-01-01T01:16:00Z. Every bed card
    then shows a "Updated <huge number>s ago" badge, even though data is
    arriving every second.
    Fix: this bridge is the single source of truth for "when did this
    reading arrive" — it overwrites packet["lastUpdated"] with its own
    wall-clock time (real Unix epoch seconds) right before emitting,
    regardless of whatever value (or lack of one) the ESP32 sent. The
    ESP32 no longer needs to send a timestamp field at all.

  BUG #6 — socketio.run() raising RuntimeError on startup.
    Newer flask-socketio versions (>=5.3) refuse to start under the
    bundled Werkzeug dev server unless allow_unsafe_werkzeug=True is
    passed explicitly, and raise instead of falling back. This was
    crashing the process on every single launch (including right after
    boot), which the app.py controller couldn't distinguish from any
    other backend failure. Fixed below by passing that flag.
    Note: this is still the Werkzeug dev server, not a production WSGI
    server. That's fine for this app (the dashboard only ever talks to
    it over 127.0.0.1/local network), but if this port is ever exposed
    beyond that, switch to eventlet/gunicorn instead of relying on this
    flag.
--------------------------------------------------------------------------
"""

import json
import os
import socket
import threading
import time

from flask import Flask, request, jsonify
from flask_socketio import SocketIO

# --------------------------------------------------------------------
# 1. Flask + Socket.IO server setup
# --------------------------------------------------------------------
app = Flask(__name__)

# === FIX (req #8): cors_allowed_origins="*" ===
# Required so the browser's Socket.IO client (served from a different
# origin than this Python process) is allowed to complete its handshake
# at all. Without this, socket.on("connect_error") fires repeatedly on
# the frontend and socket.on("connect") never fires.
#
# async_mode="threading" is used deliberately (see udp_listener() below):
# it lets a plain Python background thread safely call socketio.emit()
# without needing eventlet/gevent monkey-patching, which keeps this file
# simple and avoids a whole class of import-order bugs.
socketio = SocketIO(
    app,
    cors_allowed_origins="*",
    async_mode="threading",
)

UDP_IP = "0.0.0.0"    # listen on every network interface, not just localhost
UDP_PORT = 5005       # must match UDP_PORT in the ESP32 sketch

# Simple, reliable connected-client counter (see requirement #4's "number
# of connected Socket.IO clients"). This is preferred over reaching into
# `socketio.server.manager.rooms` directly, since that's a private
# implementation detail of python-socketio and its shape can change
# between versions — these two handlers give the same information
# through the public API.
connected_clients = 0


@socketio.on("connect")
def handle_connect():
    global connected_clients
    connected_clients += 1
    print(f"[Socket.IO] Client connected. Total clients: {connected_clients}")


@socketio.on("disconnect")
def handle_disconnect():
    global connected_clients
    connected_clients = max(0, connected_clients - 1)
    print(f"[Socket.IO] Client disconnected. Total clients: {connected_clients}")


# --------------------------------------------------------------------
# 1b. Admin settings API — password-protected kiosk mode toggle
# --------------------------------------------------------------------
CONFIG_PATH = os.path.abspath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, "config.json")
)


def load_config():
    with open(CONFIG_PATH, "r") as f:
        return json.load(f)


def save_config(cfg):
    with open(CONFIG_PATH, "w") as f:
        json.dump(cfg, f, indent=4)


@app.after_request
def add_cors_headers(response):
    # The dashboard (port 8080) and this API (port 3000) are different
    # origins as far as the browser is concerned, so plain HTTP requests
    # (not Socket.IO) need their own CORS headers too.
    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["Access-Control-Allow-Headers"] = "Content-Type"
    response.headers["Access-Control-Allow-Methods"] = "GET,POST,OPTIONS"
    return response


@app.route("/api/settings", methods=["GET"])
def get_settings():
    cfg = load_config()
    return jsonify({
        "kiosk_mode": cfg.get("kiosk_mode", True),
        "theme": cfg.get("theme", "dark"),
    })


@app.route("/api/settings/theme", methods=["POST", "OPTIONS"])
def set_theme():
    # No password required (unlike kiosk-mode) -- this only affects
    # display appearance, not the ability to exit the kiosk, so it isn't
    # security-sensitive the same way.
    if request.method == "OPTIONS":
        return "", 200

    data = request.get_json(silent=True) or {}
    theme = data.get("theme")
    if theme not in ("dark", "light"):
        return jsonify({"success": False, "error": "theme must be 'dark' or 'light'"}), 400

    cfg = load_config()
    cfg["theme"] = theme
    save_config(cfg)
    print(f"[Settings] theme changed to {theme}")
    return jsonify({"success": True, "theme": theme})


@app.route("/api/settings/kiosk-mode", methods=["POST", "OPTIONS"])
def set_kiosk_mode():
    if request.method == "OPTIONS":
        return "", 200

    data = request.get_json(silent=True) or {}
    password = data.get("password", "")
    kiosk_mode = data.get("kiosk_mode")

    cfg = load_config()
    if password != cfg.get("admin_password"):
        return jsonify({"success": False, "error": "Incorrect password"}), 401

    if kiosk_mode is None:
        return jsonify({"success": False, "error": "Missing kiosk_mode"}), 400

    cfg["kiosk_mode"] = bool(kiosk_mode)
    save_config(cfg)
    print(f"[Settings] kiosk_mode changed to {cfg['kiosk_mode']} via admin panel")
    return jsonify({"success": True, "kiosk_mode": cfg["kiosk_mode"]})


# --------------------------------------------------------------------
# 2. UDP listener — runs in its own background thread (BUG FIX #1)
# --------------------------------------------------------------------
def udp_listener():
    """
    Blocking UDP receive loop. Must run in a dedicated thread (started
    from start_udp_listener() below, BEFORE socketio.run() is called on
    the main thread) so it never blocks — and is never blocked by —
    the Socket.IO server's own request handling.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((UDP_IP, UDP_PORT))
    print(f"[UDP] Listening on {UDP_IP}:{UDP_PORT}")

    while True:
        try:
            data, addr = sock.recvfrom(4096)
        except Exception as e:
            print(f"[UDP] Socket error: {e}")
            continue

        raw_text = data.decode("utf-8", errors="replace")

        # === Debug logging (req #1): exact packet + type as received ===
        print("UDP RECEIVED:", raw_text)
        print(type(raw_text))

        # === FIX (BUG #2 / req #2): parse to a real dict BEFORE emitting ===
        try:
            packet = json.loads(raw_text)
        except json.JSONDecodeError as e:
            print(f"[UDP] JSON decode FAILED: {e}")
            continue

        # === req #2 (continued): guard against DOUBLE-encoded JSON.
        # Normally json.loads() on a valid packet already returns a dict.
        # But if the ESP32 (or anything upstream) accidentally serializes
        # the JSON twice, json.loads() here would return a *string* that
        # itself still looks like `{"bed":1,...}` rather than a dict. If
        # that happens, decode it a second time. ===
        if isinstance(packet, str):
            print("[UDP] WARNING: packet was still a string after json.loads() — decoding again")
            packet = json.loads(packet)

        print("[UDP] Packet type after decode:", type(packet))
        print("[UDP] JSON decoded successfully:", packet)

        # === req #9: guard against a nested payload, e.g. {"data": {...}}.
        # If the top level has no "bed" key but does have "data", unwrap it
        # here so the frontend always receives the flat shape it expects
        # ({"bed":..., "position":..., "risk":..., "plates":..., "lastUpdated":...})
        # without needing any frontend changes. ===
        if "bed" not in packet and isinstance(packet.get("data"), dict):
            print("[UDP] Packet was nested under 'data' — unwrapping before emit")
            packet = packet["data"]

        # === req #8: coerce packet.bed to a real number if the ESP32 (or
        # ArduinoJson) ever sends it as a string like "1" instead of 1.
        # JavaScript's `typeof packet.bed !== "number"` guard on the
        # frontend depends on this being a true numeric type. ===
        if "bed" in packet and isinstance(packet["bed"], str):
            print(f"[UDP] WARNING: packet.bed was a string ('{packet['bed']}') — converting to int")
            try:
                packet["bed"] = int(packet["bed"])
            except ValueError:
                print(f"[UDP] Could not convert packet.bed to int, skipping packet: {packet}")
                continue

        # === FIX (BUG #5): stamp the ARRIVAL time here on the Pi, in real
        # Unix epoch seconds, and always overwrite whatever the ESP32 sent
        # (or didn't send) for "lastUpdated". The ESP32's own counter/clock
        # is not epoch time and must never reach the frontend as if it
        # were one — that was silently producing a garbage "Updated ...s
        # ago" badge on every bed card. This is now the single source of
        # truth for that field. ===
        packet["lastUpdated"] = time.time()

        # --- Debug logging (req #3): print immediately before emitting ---
        print("EMITTING:", packet)

        # === Requirement #4: emit exactly "patientData" and nothing
        #     else, matching the frontend's socket.on("patientData", ...) ===
        socketio.emit("patientData", packet)

        # --- Debug logging (req #5): socketio.emit() executed + client count ---
        print("[Socket.IO] Emitted 'patientData' ->", packet)
        print(f"[Socket.IO] Currently connected clients: {connected_clients}")


def start_udp_listener():
    thread = threading.Thread(target=udp_listener, daemon=True)
    thread.start()


# --------------------------------------------------------------------
# 3. Entry point
# --------------------------------------------------------------------
if __name__ == "__main__":
    # Start the UDP thread FIRST, then hand control to socketio.run() on
    # the main thread. Order matters: if socketio.run() were called
    # first, it never returns, so the line starting the UDP thread would
    # never execute (BUG FIX #1 depends on this ordering too).
    start_udp_listener()

    # === FIX (BUG #4): socketio.run(), not app.run() ===
    # === FIX (req #11): host="0.0.0.0", port=3000 ===
    # === FIX (BUG #6): allow_unsafe_werkzeug=True — newer flask-socketio
    # refuses to start without this and raises RuntimeError instead,
    # which was crashing the backend on every boot. See module docstring
    # BUG #6 above. ===
    print("[Server] Starting Flask-SocketIO on 0.0.0.0:3000")
    socketio.run(app, host="0.0.0.0", port=3000, allow_unsafe_werkzeug=True)
