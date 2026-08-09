import React, { useState, useEffect, useRef, useCallback, useMemo } from "react";
import * as THREE from "three";
import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";

/* Drop your own patient model at ./models/patient.glb (or .gltf) and it will be
   loaded automatically in the 3D bed view, in place of the built-in procedural
   figure. The bed and the model's sleeping position/pose are left untouched —
   only the room around the bed is styled like a hospital bay. */
const CUSTOM_MODEL_PATH = "./models/patient.glb";
const BED_MODEL_PATH = "./models/hospital_bed.glb";
// Verified against the actual patient.glb: it's a static mesh (no skeleton/
// animation), so its arms are permanently held out from its sides — that's
// baked into the geometry and can't be changed by rotating/scaling it. The
// real bug causing the "perpendicular"/oversized look was the bed model's
// rotation, which is now self-correcting (see below), so the custom patient
// model is back on.
const USE_CUSTOM_PATIENT_MODEL = true;
import {
  Activity, AlertTriangle, Bell, Settings, LogOut, ChevronLeft, ChevronRight,
  LayoutGrid, Radio, History, FileBarChart, PieChart as PieIcon, BellRing, Wifi, WifiOff,
  Moon, Sun, X, Check, Volume2, VolumeX, User, Bed as BedIcon, Clock, Gauge,
  ShieldAlert, HeartPulse, Download, RotateCw, Save, Search, Power
} from "lucide-react";
import {
  LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer,
  PieChart, Pie, Cell, BarChart, Bar, Legend
} from "recharts";

// === SOCKET.IO COMMUNICATION LAYER CHANGE ===
// The backend is Flask-SocketIO, not a native WebSocket server, so the raw
// `new WebSocket(...)` connection is replaced with the Socket.IO client.
import { io } from "socket.io-client";

/* ------------------------------------------------------------------
   VitalS — Hospital Bed Ulcer Prevention & Monitoring System (v2)
   Font stack: Inter, Segoe UI, Roboto (per request) — one face, weight does the work.
   Sidebar: sky-blue surface, deep-blue active state.
------------------------------------------------------------------- */

const FONT_LINK_ID = "vitals-fonts";
function useFonts() {
  useEffect(() => {
    if (document.getElementById(FONT_LINK_ID)) return;
    const link = document.createElement("link");
    link.id = FONT_LINK_ID;
    link.rel = "stylesheet";
    link.href =
      "https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=Roboto:wght@400;500;700&display=swap";
    document.head.appendChild(link);
  }, []);
}

const WARDS = ["Medical ICU", "Surgical ICU", "Cardiac Care", "Neuro ICU", "Trauma Unit", "Post-Op Ward", "Ortho Ward", "General Ward"];
const NAMES = [
  { name: "Margaret Chen", age: 74, gender: "F" },
  { name: "Robert Alvarez", age: 68, gender: "M" },
  { name: "Susan Whitfield", age: 81, gender: "F" },
  { name: "James Okafor", age: 59, gender: "M" },
  { name: "Elena Petrova", age: 77, gender: "F" },
  { name: "David Kim", age: 63, gender: "M" },
  { name: "Grace Thompson", age: 85, gender: "F" },
  { name: "Marcus Webb", age: 70, gender: "M" },
];
const POSITIONS = ["Supine", "Left Lateral", "Right Lateral", "Prone", "Sitting"];
const RISK_ORDER = ["Normal", "Medium", "High", "Critical"];
const RISK_COLOR = {
  Normal: { fg: "var(--risk-normal-fg)", bg: "var(--risk-normal-bg)", ring: "var(--risk-normal-ring)", hex: 0x1f9d55 },
  Medium: { fg: "var(--risk-medium-fg)", bg: "var(--risk-medium-bg)", ring: "var(--risk-medium-ring)", hex: 0xe8a318 },
  High: { fg: "var(--risk-high-fg)", bg: "var(--risk-high-bg)", ring: "var(--risk-high-ring)", hex: 0xf0791f },
  Critical: { fg: "var(--risk-crit-fg)", bg: "var(--risk-crit-bg)", ring: "var(--risk-crit-ring)", hex: 0xe23b3b },
};
const PLATE_ZONE = ["Shoulders", "Mid-Back", "Hips / Sacrum", "Heels"];
const BODY_PART = {
  Supine: "Sacrum / Heels",
  "Left Lateral": "Left Hip / Ankle",
  "Right Lateral": "Right Hip / Ankle",
  Prone: "Chest / Knees",
  Sitting: "Ischial Tuberosities",
};

function randWalk(v, min, max, step) {
  const n = v + (Math.random() - 0.5) * step;
  return Math.max(min, Math.min(max, n));
}

function computeRisk(plates, minutesInPosition, thresholds) {
  const maxPlate = Math.max(...plates);
  let score = 0;
  if (maxPlate > 850) score += 3;
  else if (maxPlate > 700) score += 2;
  else if (maxPlate > 550) score += 1;
  if (minutesInPosition > thresholds.critMin) score += 3;
  else if (minutesInPosition > thresholds.warnMin * 1.5) score += 2;
  else if (minutesInPosition > thresholds.warnMin) score += 1;
  if (score >= 5) return "Critical";
  if (score >= 4) return "High";
  if (score >= 2) return "Medium";
  return "Normal";
}

function valueToColorHex(v) {
  // green -> yellow -> orange -> red
  const stops = [
    { at: 0, c: [31, 157, 85] },
    { at: 450, c: [232, 163, 24] },
    { at: 700, c: [240, 121, 31] },
    { at: 950, c: [226, 59, 59] },
  ];
  let a = stops[0], b = stops[stops.length - 1];
  for (let i = 0; i < stops.length - 1; i++) {
    if (v >= stops[i].at && v <= stops[i + 1].at) { a = stops[i]; b = stops[i + 1]; break; }
  }
  const t = Math.max(0, Math.min(1, (v - a.at) / (b.at - a.at || 1)));
  const r = Math.round(a.c[0] + (b.c[0] - a.c[0]) * t);
  const g = Math.round(a.c[1] + (b.c[1] - a.c[1]) * t);
  const bl = Math.round(a.c[2] + (b.c[2] - a.c[2]) * t);
  return (r << 16) | (g << 8) | bl;
}
function hexToCss(hex) { return "#" + hex.toString(16).padStart(6, "0"); }

function fmtDuration(sec) {
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const s = Math.floor(sec % 60);
  const pad = (n) => String(n).padStart(2, "0");
  return `${pad(h)} hr ${pad(m)} min ${pad(s)} sec`;
}
function fmtDurationShort(sec) {
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  return `${String(h).padStart(2, "0")} hr ${String(m).padStart(2, "0")} min`;
}

function makeInitialPatients() {
  // No randomized/fabricated readings here. Every bed starts at a neutral
  // "no data yet" state (zeroed plates, no elapsed position time) and only
  // ever changes when a real UDP packet arrives for that bed's number via
  // socket.on("patientData", ...). `hasLiveData` tracks whether a real
  // packet has ever been received, so the UI can distinguish "no sensor
  // data yet" from an actual live zero reading.
  return NAMES.map((p, i) => {
    const position = POSITIONS[i % POSITIONS.length];
    return {
      id: i + 1,
      name: p.name,
      patientId: `PT-${1000 + i}`,
      age: p.age,
      gender: p.gender,
      ward: WARDS[i],
      bed: i + 1,
      position,
      positionSince: Date.now(),
      plates: [0, 0, 0, 0],
      risk: "Normal",
      lastUpdated: null,
      sensorsOnline: 0, // real count of reporting plates for this bed — see the "hasLiveData" update below
      ack: false,
      hasLiveData: false,
    };
  });
}

function useCountUp(target, duration = 900) {
  const [val, setVal] = useState(0);
  const startRef = useRef(null);
  const fromRef = useRef(0);
  useEffect(() => {
    fromRef.current = val;
    startRef.current = null;
    let raf;
    const step = (ts) => {
      if (startRef.current === null) startRef.current = ts;
      const p = Math.min(1, (ts - startRef.current) / duration);
      const eased = 1 - Math.pow(1 - p, 3);
      setVal(fromRef.current + (target - fromRef.current) * eased);
      if (p < 1) raf = requestAnimationFrame(step);
    };
    raf = requestAnimationFrame(step);
    return () => cancelAnimationFrame(raf);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [target, duration]);
  return val;
}

function Sparkline({ value, color }) {
  const historyRef = useRef(Array.from({ length: 24 }, () => value));
  const [, force] = useState(0);
  useEffect(() => {
    historyRef.current = [...historyRef.current.slice(1), value];
    force((n) => n + 1);
  }, [value]);
  const h = historyRef.current;
  const max = Math.max(...h, 1);
  const min = Math.min(...h);
  const range = Math.max(max - min, 1);
  const pts = h
    .map((v, i) => {
      const x = (i / (h.length - 1)) * 60;
      const y = 20 - ((v - min) / range) * 18 - 1;
      return `${x},${y}`;
    })
    .join(" ");
  return (
    <svg width="60" height="20" viewBox="0 0 60 20" className="vs-spark">
      <polyline points={pts} fill="none" stroke={color} strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

const NAV_ITEMS = [
  { key: "dashboard", label: "Dashboard", icon: LayoutGrid },
  { key: "live", label: "Live Monitoring", icon: Radio },
  { key: "alerts", label: "Emergency Alerts", icon: ShieldAlert },
  { key: "history", label: "Patient History", icon: History },
  { key: "reports", label: "Reports", icon: FileBarChart },
  { key: "analytics", label: "Analytics", icon: PieIcon },
  { key: "notifications", label: "Notifications", icon: BellRing },
  { key: "settings", label: "Settings", icon: Settings },
];

export default function VitalS() {
  useFonts();
  const [dark, setDark] = useState(true);
  // === THEME PERSISTENCE ===
  // Mirrors the existing kiosk_mode pattern: the saved theme lives in
  // config.json on the Pi (via the backend's /api/settings endpoints),
  // not in localStorage/sessionStorage, since this is a kiosk WebView
  // that should reopen in whichever theme was last chosen even after a
  // full reboot. themeLoaded gates the persistence effect below so the
  // initial fetch (which sets `dark` from what's saved) doesn't
  // immediately re-save that same value right back.
  const [themeLoaded, setThemeLoaded] = useState(false);
  const [collapsed, setCollapsed] = useState(false);
  const [activeNav, setActiveNav] = useState("dashboard");
  const [now, setNow] = useState(Date.now());
  // === SOCKET.IO COMMUNICATION LAYER CHANGE ===
  // mqttConnected is kept (same name, same boolean meaning) so the existing
  // connection-indicator JSX/CSS below doesn't need to change — it now
  // reflects the real Socket.IO connection instead of the old fake MQTT
  // flakiness simulator. wsStatusLabel drives the visible text so it can
  // show "Connecting…"/"Connected"/"Disconnected"/"Reconnecting…".
  // (wsRef/wsReconnectTimeoutRef names kept as-is; they now hold the
  // Socket.IO client instance and its manual-reconnect timer, respectively.)
  const [mqttConnected, setMqttConnected] = useState(false);
  const [wsStatusLabel, setWsStatusLabel] = useState("Connecting…");
  const wsRef = useRef(null);
  const wsReconnectTimeoutRef = useRef(null);
  const [patients, setPatients] = useState(makeInitialPatients);
  const [historyMap, setHistoryMap] = useState(() => {
    const m = {};
    NAMES.forEach((_, i) => (m[i + 1] = []));
    return m;
  });
  const [log, setLog] = useState([
    { id: 1, time: new Date(), bed: null, text: "System initialized — 64/64 sensors online", kind: "info" },
  ]);
  const [emergencyQueue, setEmergencyQueue] = useState([]);
  const [activeEmergency, setActiveEmergency] = useState(null);
  const [muted, setMuted] = useState(false);
  const [toasts, setToasts] = useState([]);
  const [notifOpen, setNotifOpen] = useState(false);
  const [view3DBedId, setView3DBedId] = useState(null);
  const [historyPatientId, setHistoryPatientId] = useState(1);
  const [searchTerm, setSearchTerm] = useState("");
  const [thresholds, setThresholds] = useState({ warnMin: 60, critMin: 120 });
  const [hospitalName, setHospitalName] = useState("St. Augustine Medical Center");
  const logIdRef = useRef(2);
  const toastIdRef = useRef(1);

  const pushLog = useCallback((bed, text, kind = "info") => {
    setLog((l) => [{ id: logIdRef.current++, time: new Date(), bed, text, kind }, ...l].slice(0, 300));
  }, []);

  const pushToast = useCallback((text, kind = "info") => {
    const id = toastIdRef.current++;
    setToasts((t) => [...t, { id, text, kind }]);
    setTimeout(() => setToasts((t) => t.filter((x) => x.id !== id)), 4200);
  }, []);

  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, []);

  // === THEME PERSISTENCE (load) ===
  // Reads the saved theme once on startup. If the backend isn't reachable
  // yet (e.g. this fetch races the backend readiness poll on a cold boot),
  // it just silently keeps the default (dark) — the theme toggle button
  // still works, it just won't have restored last time's choice.
  useEffect(() => {
    fetch("http://127.0.0.1:3000/api/settings")
      .then((r) => r.json())
      .then((d) => setDark(d.theme !== "light"))
      .catch(() => {})
      .finally(() => setThemeLoaded(true));
  }, []);

  // === THEME PERSISTENCE (save) ===
  // Fires every time the user toggles the theme (but not on the initial
  // load above, thanks to the themeLoaded gate) and saves the choice back
  // to config.json so it survives a reboot.
  useEffect(() => {
    if (!themeLoaded) return;
    fetch("http://127.0.0.1:3000/api/settings/theme", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ theme: dark ? "dark" : "light" }),
    }).catch(() => {});
  }, [dark, themeLoaded]);

  // === WEBSOCKET LIVE DATA CHANGE ===
  // Replaces both of the removed simulation effects above:
  //   1) the fake "MQTT broker disconnected/reconnected" flakiness timer, and
  //   2) the setInterval() that random-walked plate pressures, occasionally
  //      changed position, and recomputed risk client-side.
  // Data now comes from one persistent WebSocket to the Raspberry Pi backend
  // (ws://192.168.137.173:3000). The backend already computes `risk` from the
  // ESP32/UDP readings, so computeRisk() is no longer called here for live
  // updates (the function itself is left intact above, untouched, in case
  // it's wanted again later).
  //
  // NOTE: per the requested field list, only `position`, `risk`, `plates`,
  // and `lastUpdated` are updated on each packet. `positionSince` (used for
  // "time in position" duration calculations elsewhere) is intentionally
  // left as-is, matching the spec — if you want reposition timers to reset
  // whenever `position` actually changes, that would be a one-line addition
  // inside the `updated` object below.
  // === SOCKET.IO COMMUNICATION LAYER CHANGE ===
  // Same responsibilities as before (open one persistent live-data
  // connection, update patients immutably, append history, drive the
  // connection indicator) — only the transport changed, because the
  // backend is Flask-SocketIO, which speaks the Socket.IO protocol on top
  // of WebSocket/polling, not plain WebSocket frames. A raw
  // `new WebSocket("ws://192.168.137.173:3000")` cannot talk to it.
  useEffect(() => {
   const SOCKET_URL = "http://127.0.0.1:3000";
    let unmounted = false;

    const scheduleReconnect = () => {
      if (wsReconnectTimeoutRef.current) clearTimeout(wsReconnectTimeoutRef.current);
      // --- 7 (part 2): reconnect automatically after 3 seconds ---
      wsReconnectTimeoutRef.current = setTimeout(() => {
        if (!unmounted) {
          setWsStatusLabel("Reconnecting…");
          connect();
        }
      }, 3000);
    };

    const connect = () => {
      setWsStatusLabel((prevLabel) => (prevLabel === "Connecting…" ? "Connecting…" : "Reconnecting…"));

      // reconnection: false — reconnects are handled manually via
      // scheduleReconnect() so behavior (a clean single retry every 3s)

      // stays identical to the previous WebSocket implementation.
      console.log("SOCKET_URL =", SOCKET_URL);
      const socket = io(SOCKET_URL, {
        reconnection: false,
        transports: ["websocket", "polling"],
      });
      wsRef.current = socket;

      // --- 7. Socket.IO connection events ---
      socket.on("connect", () => {
        if (unmounted) return;
        console.log("Socket Connected"); // === DEBUG LOGGING (req #1): confirms the client actually completed the handshake ===
        setMqttConnected(true);
        setWsStatusLabel("Connected");
        pushLog(null, "Socket.IO connected to Raspberry Pi backend", "ok");
        pushToast("Socket.IO connected", "ok");
      });

      // --- 3. Replaces socket.onmessage: backend emits socketio.emit("patientData", packet) ---
      socket.on("patientData", (packet) => {
        console.log("Received packet:", packet); // === DEBUG LOGGING (req #6): confirms socket.on("patientData") actually fires ===
        console.log(typeof packet); // === DEBUG LOGGING (req #7) ===
        console.log(packet); // === DEBUG LOGGING (req #7) ===

        // === req #9: defensive nested-payload guard. udp_server.py already
        // unwraps a { "data": {...} } shape before emitting, but this stays
        // here too in case a different/older backend build ever emits the
        // nested form again — the frontend then still reads packet.data
        // without needing another round of changes. ===
        if (packet && typeof packet === "object" && !("bed" in packet) && packet.data && typeof packet.data === "object") {
          console.log("Packet was nested under 'data' — unwrapping on the frontend:", packet.data);
          packet = packet.data;
        }

        // === req #8: coerce packet.bed to a real Number if it ever arrives
        // as a string like "1" (e.g. from a template/serializer that quotes
        // numeric fields). The validity check right below requires a true
        // "number" typeof, so this must happen before that check runs. ===
        if (packet && typeof packet.bed === "string") {
          console.log(`packet.bed arrived as a string ("${packet.bed}") — converting with Number()`);
          packet.bed = Number(packet.bed);
        }

        // === DEBUG LOGGING (req #15): print the packet immediately before
        // the early-return guard below, so if the dashboard ever silently
        // stops updating again, the console shows exactly what was
        // rejected and why (missing/undefined packet, wrong type on bed,
        // NaN from a failed Number() conversion above, etc.). ===
        console.log("Packet before validity check:", packet, "| typeof packet.bed:", typeof packet?.bed);
        if (!packet || typeof packet.bed !== "number" || Number.isNaN(packet.bed)) return;

        // === DEBUG LOGGING (req #12): confirms setPatients() is actually
        // about to be invoked for this packet (as opposed to, say, an
        // exception earlier in this handler silently aborting it). ===
        console.log("Calling setPatients() for bed", packet.bed);

        // --- 4/5/6. Live update logic: find patient by bed, update only
        //     the required fields with an immutable array update (only the
        //     matched patient's object is replaced; every other patient
        //     object keeps its original reference). ---
        setPatients((prev) => {
          console.log("Before update", prev); // === DEBUG LOGGING (req #10) ===
          console.log("Updating Bed", packet.bed); // === DEBUG LOGGING (req #10) ===

          const idx = prev.findIndex((p) => p.bed === packet.bed);
          if (idx === -1) {
            console.log("No patient found with bed ===", packet.bed, "- ignoring packet, array reference unchanged");
            return prev; // unknown bed — no-op, same array reference
          }

          const p = prev[idx];
          const prevRisk = p.risk;
          const nextRisk = packet.risk ?? p.risk;
          const nextPosition = packet.position ?? p.position;
          const positionChanged = typeof packet.position !== "undefined" && packet.position !== p.position;

          // Reuse the existing log/toast behavior so Notifications, Alerts,
          // and the Emergency modal (requirement 7 from the live-data task)
          // keep working unchanged.
          if (positionChanged) {
            pushLog(p.bed, `Patient repositioned: ${p.position} → ${nextPosition}`, "ok");
            pushToast("Patient Repositioned Successfully", "ok");
          }
          if (nextRisk !== prevRisk) {
            pushLog(p.bed, `Risk level changed: ${prevRisk} → ${nextRisk}`, nextRisk === "Normal" ? "ok" : "danger");
            if (RISK_ORDER.indexOf(nextRisk) >= 2 && RISK_ORDER.indexOf(prevRisk) < 2) {
              pushToast(`Bed ${p.bed}: Risk increased to ${nextRisk}`, "danger");
            } else if (RISK_ORDER.indexOf(nextRisk) < 2 && RISK_ORDER.indexOf(prevRisk) >= 2) {
              pushToast(`Bed ${p.bed}: Risk cleared — back to Normal`, "ok");
            }
          }

          const updated = {
            ...p,
            position: nextPosition,
            risk: nextRisk,
            plates: Array.isArray(packet.plates) ? packet.plates : p.plates,
            // --- 6. Protect against missing timestamps ---
            lastUpdated: packet.lastUpdated ? packet.lastUpdated * 1000 : Date.now(),
            // --- 5. Reset positionSince so the "time in position" timer restarts ---
            positionSince: positionChanged ? Date.now() : p.positionSince,
            // Not in the required field list, but kept so the existing
            // emergency-alert system keeps re-triggering correctly the next
            // time risk rises again after being acknowledged.
            ack: nextRisk === prevRisk ? p.ack : false,
            // This bed has now received at least one real UDP packet — the
            // UI can stop showing it as "no data yet".
            hasLiveData: true,
            // Real sensor count = however many plate readings this packet
            // actually contained, not a fabricated constant.
            sensorsOnline: Array.isArray(packet.plates) ? packet.plates.length : p.sensorsOnline,
          };

          console.log("After update", updated); // === DEBUG LOGGING (req #11) ===

          // req #13/#14: this creates a NEW array reference (prev.slice())
          // containing a NEW object reference at `idx` (the `updated`
          // object above) while every other patient object in the array
          // keeps its original reference. BedCard is rendered as
          // <BedCard key={p.id} p={p} .../> from this same `patients` array
          // further down the tree, so: (a) the array reference change makes
          // the parent re-render, and (b) the changed object reference at
          // this one index means only that bed's BedCard actually re-renders
          // with new data — other beds' BedCards skip re-rendering because
          // their prop reference didn't change. This is expected/correct
          // React behavior, not a bug — if BedCard were wrapped in
          // React.memo with a custom comparator that ignores `p`, that would
          // be the one place a real re-render bug could hide, but no such
          // memoization exists in this codebase (BedCard is a plain
          // function component here), so no fix is needed here.
          const next = prev.slice();
          next[idx] = updated;
          return next;
        });

        // Patient history: append this one packet directly.
        setHistoryMap((prevMap) => {
          const id = packet.bed; // patient.id === patient.bed by construction (see makeInitialPatients)
          const arr = [...(prevMap[id] || []), {
            t: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" }),
            p1: packet.plates?.[0], p2: packet.plates?.[1], p3: packet.plates?.[2], p4: packet.plates?.[3],
            riskScore: RISK_ORDER.indexOf(packet.risk),
          }];
          return { ...prevMap, [id]: arr.slice(-60) };
        });
      });

      socket.on("disconnect", (reason) => {
        if (unmounted) return;
        console.log(reason); // === DEBUG LOGGING (req #10): shows *why* Socket.IO dropped (e.g. "transport close", "io server disconnect") ===
        setMqttConnected(false);
        setWsStatusLabel("Disconnected");
        pushLog(null, `Socket.IO disconnected (${reason}) — retrying in 3s`, "warn");
        pushToast("Socket.IO disconnected", "warn");
        scheduleReconnect();
      });

      socket.on("connect_error", (err) => {
        if (unmounted) return;
        console.error(err); // === DEBUG LOGGING (req #10): surfaces handshake failures (CORS, wrong URL, version mismatch, etc.) ===
        setMqttConnected(false);
        setWsStatusLabel("Reconnecting…");
        // === FIX (req #16): use socket.disconnect(), the correct Socket.IO
        // client method, instead of socket.close() (a WebSocket-era name
        // left over from the earlier raw-WebSocket version of this file). ===
        socket.disconnect();
        scheduleReconnect();
      });
    };

    connect();

    // --- Code quality: close the socket and clear any pending reconnect
    //     timer when the component unmounts, to avoid memory leaks. ---
    return () => {
      unmounted = true;
      if (wsReconnectTimeoutRef.current) clearTimeout(wsReconnectTimeoutRef.current);
      if (wsRef.current) wsRef.current.disconnect(); // === FIX (req #16): was socket.close() ===
    };
  }, [pushLog, pushToast]);

  useEffect(() => {
    const critical = patients.filter((p) => (p.risk === "High" || p.risk === "Critical") && !p.ack);
    setEmergencyQueue(critical.map((p) => p.id));
  }, [patients]);

  useEffect(() => {
    if (!activeEmergency && emergencyQueue.length > 0) setActiveEmergency(emergencyQueue[0]);
    if (activeEmergency && !emergencyQueue.includes(activeEmergency)) setActiveEmergency(emergencyQueue[0] || null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [emergencyQueue]);

  const acknowledge = (id) => {
    setPatients((prev) => prev.map((p) => (p.id === id ? { ...p, ack: true } : p)));
    const p = patients.find((x) => x.id === id);
    if (p) pushLog(p.bed, "Emergency alert acknowledged", "ok");
    setActiveEmergency(null);
  };

  const criticalCount = patients.filter((p) => p.risk === "Critical").length;
  const atRiskCount = patients.filter((p) => RISK_ORDER.indexOf(p.risk) >= 1).length;
  const repositionCount = patients.filter((p) => (Date.now() - p.positionSince) / 60000 > thresholds.warnMin).length;
  const avgDurationSec = patients.reduce((s, p) => s + (Date.now() - p.positionSince) / 1000, 0) / patients.length;
  const sensorsOnline = patients.reduce((s, p) => s + p.sensorsOnline, 0);
  const emergencyMode = criticalCount >= 2;

  const sortedPatients = useMemo(() => {
    if (!emergencyMode) return patients;
    return [...patients].sort((a, b) => RISK_ORDER.indexOf(b.risk) - RISK_ORDER.indexOf(a.risk));
  }, [patients, emergencyMode]);

  const filteredPatients = useMemo(() => {
    if (!searchTerm.trim()) return patients;
    const q = searchTerm.toLowerCase();
    return patients.filter((p) =>
      p.name.toLowerCase().includes(q) || p.patientId.toLowerCase().includes(q) ||
      String(p.bed).includes(q) || p.ward.toLowerCase().includes(q) ||
      p.risk.toLowerCase().includes(q) || p.position.toLowerCase().includes(q)
    );
  }, [patients, searchTerm]);

  const activePatient = patients.find((p) => p.id === activeEmergency);
  const view3DPatient = patients.find((p) => p.id === view3DBedId);

  const exportCSV = () => {
    const header = ["Bed", "Patient", "PatientID", "Ward", "Position", "Plate1", "Plate2", "Plate3", "Plate4", "Risk", "TimeInPositionSec"];
    const rows = patients.map((p) => [
      p.bed, p.name, p.patientId, p.ward, p.position,
      p.plates[0], p.plates[1], p.plates[2], p.plates[3], p.risk,
      Math.round((Date.now() - p.positionSince) / 1000),
    ]);
    const csv = [header, ...rows].map((r) => r.join(",")).join("\n");
    const blob = new Blob([csv], { type: "text/csv" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `vitals-report-${new Date().toISOString().slice(0, 10)}.csv`;
    a.click();
    URL.revokeObjectURL(url);
    pushToast("CSV report downloaded", "ok");
    pushLog(null, "Report exported (CSV)", "info");
  };

  return (
    <div className={`vs-root ${dark ? "vs-dark" : ""}`}>
      <style>{CSS}</style>

      <header className={`vs-header ${emergencyMode ? "vs-header-emergency" : ""}`}>
        <div className="vs-header-left">
          <button className="vs-icon-btn vs-only-mobile" onClick={() => setCollapsed((c) => !c)}>
            {collapsed ? <ChevronRight size={18} /> : <ChevronLeft size={18} />}
          </button>
          <div className="vs-brand">
            <div className="vs-brand-mark"><HeartPulse size={22} strokeWidth={2.4} /></div>
            <div className="vs-brand-text">
              <span className="vs-brand-name">VitalS</span>
              <span className="vs-brand-sub">Hospital Bed Ulcer Prevention &amp; Monitoring System</span>
            </div>
          </div>
        </div>

        <div className="vs-header-mid">
          <span className="vs-hospital-name">{hospitalName}</span>
          <span className="vs-dot">•</span>
          <span className="vs-date">
            {new Date(now).toLocaleDateString(undefined, { weekday: "short", year: "numeric", month: "short", day: "numeric" })}
          </span>
          <span className="vs-clock">{new Date(now).toLocaleTimeString()}</span>
        </div>

        <div className="vs-header-right">
          {/* === WEBSOCKET LIVE DATA CHANGE ===: text now driven by wsStatusLabel
              ("Connecting…" / "Connected" / "Disconnected" / "Reconnecting…")
              instead of two hard-coded MQTT strings. Same element, same classes. */}
          <div className={`vs-mqtt ${mqttConnected ? "ok" : "down"}`}>
            {mqttConnected ? <Wifi size={15} /> : <WifiOff size={15} />}
            <span>{wsStatusLabel}</span>
          </div>
          <div className="vs-active-count"><Activity size={15} /><span>{patients.length} Active Patients</span></div>

          <button className="vs-icon-btn" onClick={() => { setMuted((m) => !m); pushToast(!muted ? "Alarm sound muted" : "Alarm sound on", "info"); }} title="Alarm sound">
            {muted ? <VolumeX size={17} /> : <Volume2 size={17} />}
          </button>
          <button className="vs-icon-btn" onClick={() => setDark((d) => !d)} title="Toggle theme">
            {dark ? <Sun size={17} /> : <Moon size={17} />}
          </button>
          <button className="vs-icon-btn vs-bell" onClick={() => setNotifOpen((o) => !o)}>
            <Bell size={17} />
            {atRiskCount > 0 && <span className="vs-badge">{atRiskCount}</span>}
          </button>

          {notifOpen && (
            <div className="vs-notif-pop">
              <div className="vs-notif-head">Notifications</div>
              <div className="vs-notif-list">
                {log.slice(0, 8).map((l) => (
                  <div key={l.id} className="vs-notif-item">
                    <span className="vs-notif-time">{l.time.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</span>
                    <span>{l.bed ? `Bed ${l.bed}: ` : ""}{l.text}</span>
                  </div>
                ))}
              </div>
              <button className="vs-notif-viewall" onClick={() => { setActiveNav("notifications"); setNotifOpen(false); }}>View all notifications</button>
            </div>
          )}

          <button className="vs-icon-btn" onClick={() => setActiveNav("settings")}><Settings size={17} /></button>

          <div className="vs-profile">
            <div className="vs-avatar">NR</div>
            <div className="vs-profile-text">
              <span className="vs-profile-name">Nurse R. Alderman</span>
              <span className="vs-profile-dept">ICU — Night Shift</span>
            </div>
          </div>
          <button className="vs-icon-btn" onClick={() => pushToast("Signed out (demo)", "info")}><LogOut size={17} /></button>
        </div>
      </header>

      <div className="vs-body">
        <nav className={`vs-sidebar ${collapsed ? "vs-collapsed" : ""}`}>
          <div className="vs-nav-list">
            {NAV_ITEMS.map((item) => {
              const Icon = item.icon;
              const active = activeNav === item.key;
              const count = item.key === "alerts" ? emergencyQueue.length : item.key === "notifications" ? log.length : null;
              return (
                <button key={item.key} className={`vs-nav-item ${active ? "vs-nav-active" : ""}`} onClick={() => setActiveNav(item.key)} title={item.label}>
                  <span className="vs-nav-highlight" />
                  <Icon size={18} />
                  {!collapsed && <span className="vs-nav-label">{item.label}</span>}
                  {!collapsed && count > 0 && <span className="vs-nav-count">{count > 99 ? "99+" : count}</span>}
                </button>
              );
            })}
          </div>
          <button className="vs-sidebar-collapse" onClick={() => setCollapsed((c) => !c)}>
            {collapsed ? <ChevronRight size={16} /> : <><ChevronLeft size={16} /><span>Collapse</span></>}
          </button>
        </nav>

        <main className="vs-main">
          {emergencyMode && (
            <div className="vs-emergency-banner"><ShieldAlert size={16} />EMERGENCY MODE — CRITICAL PATIENTS: {criticalCount}</div>
          )}

          {activeNav === "dashboard" && (
            <DashboardView
              patients={sortedPatients} now={now} emergencyMode={emergencyMode}
              criticalCount={criticalCount} atRiskCount={atRiskCount} repositionCount={repositionCount}
              avgDurationSec={avgDurationSec} sensorsOnline={sensorsOnline} log={log}
              onOpen3D={setView3DBedId} thresholds={thresholds}
            />
          )}
          {activeNav === "live" && (
            <LiveMonitoringView patients={filteredPatients} now={now} searchTerm={searchTerm} setSearchTerm={setSearchTerm} onOpen3D={setView3DBedId} />
          )}
          {activeNav === "alerts" && (
            <AlertsView patients={patients} log={log} onAcknowledge={acknowledge} />
          )}
          {activeNav === "history" && (
            <HistoryView patients={patients} historyMap={historyMap} selectedId={historyPatientId} setSelectedId={setHistoryPatientId} />
          )}
          {activeNav === "reports" && (
            <ReportsView patients={patients} onExport={exportCSV} />
          )}
          {activeNav === "analytics" && (
            <AnalyticsView patients={patients} />
          )}
          {activeNav === "notifications" && (
            <NotificationsView log={log} />
          )}
          {activeNav === "settings" && (
            <SettingsView
              thresholds={thresholds} setThresholds={setThresholds}
              dark={dark} setDark={setDark} muted={muted} setMuted={setMuted}
              hospitalName={hospitalName} setHospitalName={setHospitalName}
              pushToast={pushToast}
            />
          )}
        </main>
      </div>

      {activePatient && (
        <EmergencyModal patient={activePatient} onAcknowledge={() => acknowledge(activePatient.id)} onSilence={() => setActiveEmergency(null)} />
      )}

      {view3DPatient && (
        <Patient3DModal patient={view3DPatient} onClose={() => setView3DBedId(null)} />
      )}

      <div className="vs-toast-stack">
        {toasts.map((t) => (
          <div key={t.id} className={`vs-toast vs-toast-${t.kind}`}>
            {t.kind === "ok" && <Check size={15} />}
            {t.kind === "danger" && <AlertTriangle size={15} />}
            {t.kind === "warn" && <Bell size={15} />}
            <span>{t.text}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

/* ---------------- Dashboard (default) view ---------------- */
function DashboardView({ patients, now, onOpen3D }) {
  const [riskFilter, setRiskFilter] = useState("All");
  const [wardFilter, setWardFilter] = useState("All");
  const [positionFilter, setPositionFilter] = useState("All");

  const criticalCount = patients.filter((p) => p.risk === "Critical").length;
  const atRiskCount = patients.filter((p) => RISK_ORDER.indexOf(p.risk) >= 1).length;
  const repositionCount = patients.filter((p) => (Date.now() - p.positionSince) / 60000 > 60).length;
  const avgDurationSec = patients.reduce((s, p) => s + (Date.now() - p.positionSince) / 1000, 0) / patients.length;
  const sensorsOnline = patients.reduce((s, p) => s + p.sensorsOnline, 0);

  const wardsInUse = useMemo(() => Array.from(new Set(patients.map((p) => p.ward))), [patients]);

  const shownPatients = useMemo(() => {
    return patients.filter((p) =>
      (riskFilter === "All" || p.risk === riskFilter) &&
      (wardFilter === "All" || p.ward === wardFilter) &&
      (positionFilter === "All" || p.position === positionFilter)
    );
  }, [patients, riskFilter, wardFilter, positionFilter]);

  const hasActiveFilter = riskFilter !== "All" || wardFilter !== "All" || positionFilter !== "All";

  return (
    <>
      <SummaryRow totalBeds={patients.length} occupied={patients.length} atRisk={atRiskCount} critical={criticalCount}
        reposition={repositionCount} avgDurationSec={avgDurationSec} sensorsOnline={sensorsOnline} />
      <div className="vs-dash-wrap">
        <div className="vs-filter-bar">
          <span className="vs-filter-label"><Search size={13} /> Filter beds:</span>
          <select className="vs-filter-select" value={riskFilter} onChange={(e) => setRiskFilter(e.target.value)}>
            <option value="All">All Risk Levels</option>
            {RISK_ORDER.map((r) => <option key={r} value={r}>{r}</option>)}
          </select>
          <select className="vs-filter-select" value={wardFilter} onChange={(e) => setWardFilter(e.target.value)}>
            <option value="All">All Wards</option>
            {wardsInUse.map((w) => <option key={w} value={w}>{w}</option>)}
          </select>
          <select className="vs-filter-select" value={positionFilter} onChange={(e) => setPositionFilter(e.target.value)}>
            <option value="All">All Positions</option>
            {POSITIONS.map((p) => <option key={p} value={p}>{p}</option>)}
          </select>
          {hasActiveFilter && (
            <button className="vs-filter-reset" onClick={() => { setRiskFilter("All"); setWardFilter("All"); setPositionFilter("All"); }}>
              Clear filters
            </button>
          )}
          <span className="vs-filter-label" style={{ marginLeft: "auto" }}>{shownPatients.length} of {patients.length} beds shown</span>
        </div>
        <div className="vs-grid">
          {shownPatients.map((p, idx) => <BedCard key={p.id} p={p} now={now} index={idx} onOpen3D={onOpen3D} />)}
          {shownPatients.length === 0 && <div className="vs-empty-card">No beds match the selected filters.</div>}
        </div>
      </div>
    </>
  );
}

function SummaryRow({ totalBeds, occupied, atRisk, critical, reposition, avgDurationSec, sensorsOnline }) {
  const stats = [
    { label: "Total Beds", value: totalBeds, icon: BedIcon, tone: "blue" },
    { label: "Occupied Beds", value: occupied, icon: User, tone: "blue" },
    { label: "Patients at Risk", value: atRisk, icon: AlertTriangle, tone: "warn" },
    { label: "Critical Patients", value: critical, icon: ShieldAlert, tone: "crit" },
    { label: "Need Reposition", value: reposition, icon: Clock, tone: "warn" },
    { label: "Sensors Online", value: sensorsOnline, icon: Gauge, tone: "blue", suffix: "/ 64" },
  ];
  return (
    <div className="vs-summary">
      {stats.map((s, i) => <StatCard key={s.label} {...s} delay={i * 60} />)}
      <div className="vs-stat-card vs-stat-appear" style={{ animationDelay: `${stats.length * 60}ms` }}>
        <div className="vs-stat-icon vs-tone-blue"><Clock size={17} /></div>
        <div className="vs-stat-text">
          <span className="vs-stat-value">{fmtDurationShort(avgDurationSec)}</span>
          <span className="vs-stat-label">Avg Position Duration</span>
        </div>
      </div>
    </div>
  );
}

function StatCard({ label, value, icon: Icon, tone, delay, suffix }) {
  const animated = useCountUp(value);
  return (
    <div className="vs-stat-card vs-stat-appear" style={{ animationDelay: `${delay}ms` }}>
      <div className={`vs-stat-icon vs-tone-${tone}`}><Icon size={17} /></div>
      <div className="vs-stat-text">
        <span className="vs-stat-value">{Math.round(animated)}{suffix ? ` ${suffix}` : ""}</span>
        <span className="vs-stat-label">{label}</span>
      </div>
    </div>
  );
}

function BedCard({ p, now, index, onOpen3D }) {
  const secondsInPosition = (now - p.positionSince) / 1000;
  const minutesIn = secondsInPosition / 60;
  const repoLabel = minutesIn > 120 ? "Immediate Reposition Required" : minutesIn > 60 ? "Reposition Soon" : "Normal";
  const repoTone = minutesIn > 120 ? "crit" : minutesIn > 60 ? "warn" : "ok";
  const colors = RISK_COLOR[p.risk];
  const riskClass = p.risk === "Critical" ? "vs-pulse-critical" : p.risk === "High" ? "vs-pulse-high" : p.risk === "Medium" ? "vs-pulse-medium" : "vs-pulse-normal";
  const secsAgo = p.lastUpdated ? Math.max(0, Math.round((now - p.lastUpdated) / 1000)) : null;

  return (
    <div className={`vs-bed-card ${riskClass} vs-card-appear`} style={{ animationDelay: `${index * 70}ms`, "--risk-ring": colors.ring }}
      onDoubleClick={() => onOpen3D(p.id)} title="Double-click for 3D bed view">
      <div className="vs-bed-top">
        <div className="vs-bed-id">
          <span className={`vs-status-dot vs-dot-${p.risk.toLowerCase()}`} />
          <span className="vs-bed-num">Bed {p.bed}</span>
        </div>
        <span className="vs-risk-pill" style={{ color: colors.fg, background: colors.bg }}>{p.risk}</span>
      </div>

      <div className="vs-patient-info">
        <div className="vs-patient-name">{p.name}</div>
        <div className="vs-patient-meta">{p.patientId} • {p.age}{p.gender}</div>
      </div>

      <div className="vs-position-row">
        <div className="vs-position"><span className="vs-position-icon">🛏️</span><span className="vs-position-label">{p.position}</span></div>
        <div className={`vs-repo-badge vs-tone-${repoTone}`}>{repoLabel}</div>
      </div>

      <div className="vs-timer"><Clock size={13} /><span className="vs-timer-value">{fmtDuration(secondsInPosition)}</span></div>

      <div className="vs-plates">
        {p.plates.map((v, i) => (
          <div className="vs-plate" key={i}>
            <div className="vs-plate-head"><span>Plate {i + 1}</span><Sparkline value={v} color={colors.fg} /></div>
            <span className="vs-plate-value">{v}</span>
          </div>
        ))}
      </div>

      <div className="vs-bed-footer">
        <span className="vs-bodypart">At risk: {BODY_PART[p.position]}</span>
        <span className="vs-updated">{p.hasLiveData ? `Updated ${secsAgo}s ago` : "No data yet"}</span>
      </div>
      <button className="vs-3d-hint" onClick={() => onOpen3D(p.id)}><RotateCw size={11} /> 3D view</button>
    </div>
  );
}

/* ---------------- Live monitoring view ---------------- */
function LiveMonitoringView({ patients, now, searchTerm, setSearchTerm, onOpen3D }) {
  return (
    <div className="vs-panel">
      <div className="vs-panel-head">
        <h2>Live Monitoring</h2>
        <div className="vs-search">
          <Search size={14} />
          <input placeholder="Search patient, bed, ward, risk…" value={searchTerm} onChange={(e) => setSearchTerm(e.target.value)} />
        </div>
      </div>
      <div className="vs-table-wrap">
        <table className="vs-table">
          <thead>
            <tr>
              <th>Bed</th><th>Patient</th><th>Ward</th><th>Position</th><th>Time in Position</th>
              <th>Plate 1</th><th>Plate 2</th><th>Plate 3</th><th>Plate 4</th><th>Risk</th><th></th>
            </tr>
          </thead>
          <tbody>
            {patients.map((p) => {
              const colors = RISK_COLOR[p.risk];
              const sec = (now - p.positionSince) / 1000;
              return (
                <tr key={p.id} className={`vs-row-risk-${p.risk.toLowerCase()}`}>
                  <td className="vs-mono">#{p.bed}</td>
                  <td>{p.name}<div className="vs-td-sub">{p.patientId}</div></td>
                  <td>{p.ward}</td>
                  <td>{p.position}</td>
                  <td className="vs-mono">{fmtDurationShort(sec)}</td>
                  {p.plates.map((v, i) => <td key={i} className="vs-mono">{v}</td>)}
                  <td><span className="vs-risk-pill" style={{ color: colors.fg, background: colors.bg }}>{p.risk}</span></td>
                  <td><button className="vs-mini-btn" onClick={() => onOpen3D(p.id)}><RotateCw size={12} /></button></td>
                </tr>
              );
            })}
            {patients.length === 0 && (
              <tr><td colSpan={11} className="vs-empty">No beds match your search.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

/* ---------------- Emergency alerts view ---------------- */
function AlertsView({ patients, log, onAcknowledge }) {
  const active = patients.filter((p) => (p.risk === "High" || p.risk === "Critical") && !p.ack);
  const historyEntries = log.filter((l) => l.text.startsWith("Risk level changed") || l.text.includes("acknowledged"));
  return (
    <div className="vs-panel">
      <div className="vs-panel-head"><h2>Emergency Alerts</h2></div>
      <h3 className="vs-subhead">Active ({active.length})</h3>
      {active.length === 0 ? (
        <div className="vs-empty-card">No active emergencies. All patients within safe thresholds.</div>
      ) : (
        <div className="vs-alert-list">
          {active.map((p) => {
            const colors = RISK_COLOR[p.risk];
            return (
              <div key={p.id} className="vs-alert-card" style={{ borderColor: colors.fg }}>
                <AlertTriangle size={18} color={colors.fg} />
                <div className="vs-alert-info">
                  <strong>Bed {p.bed} — {p.name}</strong>
                  <span>{p.ward} • {p.position} • Risk: <span style={{ color: colors.fg, fontWeight: 700 }}>{p.risk}</span></span>
                </div>
                <button className="vs-btn vs-btn-primary" onClick={() => onAcknowledge(p.id)}><Check size={14} /> Acknowledge</button>
              </div>
            );
          })}
        </div>
      )}
      <h3 className="vs-subhead">Alert History</h3>
      <div className="vs-log-list vs-log-list-static">
        {historyEntries.slice(0, 40).map((l) => (
          <div className="vs-log-item" key={l.id}>
            <span className="vs-log-time">{l.time.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" })}</span>
            {l.bed && <span className="vs-log-bed">Bed {l.bed}</span>}
            <span className="vs-log-text">{l.text}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

/* ---------------- Patient history view ---------------- */
function HistoryView({ patients, historyMap, selectedId, setSelectedId }) {
  const patient = patients.find((p) => p.id === selectedId) || patients[0];
  const data = historyMap[patient.id] || [];
  return (
    <div className="vs-panel">
      <div className="vs-panel-head"><h2>Patient History</h2></div>
      <div className="vs-history-layout">
        <div className="vs-patient-picker">
          {patients.map((p) => (
            <button key={p.id} className={`vs-picker-item ${p.id === patient.id ? "active" : ""}`} onClick={() => setSelectedId(p.id)}>
              <span className={`vs-status-dot vs-dot-${p.risk.toLowerCase()}`} />
              Bed {p.bed} — {p.name}
            </button>
          ))}
        </div>
        <div className="vs-history-content">
          <div className="vs-history-title">
            {patient.name} <span className="vs-td-sub">({patient.patientId})</span> — {patient.ward}, Bed {patient.bed}
          </div>
          <span className="vs-history-note">Session history (resets on reload) — last ~2 minutes of samples shown</span>
          <div className="vs-chart-box">
            <ResponsiveContainer width="100%" height={240}>
              <LineChart data={data}>
                <CartesianGrid strokeDasharray="3 3" stroke="var(--line)" />
                <XAxis dataKey="t" tick={{ fontSize: 10, fill: "var(--ink-soft)" }} minTickGap={30} />
                <YAxis tick={{ fontSize: 10, fill: "var(--ink-soft)" }} domain={[0, 950]} />
                <Tooltip contentStyle={{ background: "var(--surface)", border: "1px solid var(--line)", borderRadius: 8, color: "var(--ink)" }} labelStyle={{ color: "var(--ink)" }} itemStyle={{ color: "var(--ink)" }} />
                <Legend wrapperStyle={{ fontSize: 11, color: "var(--ink)" }} />
                <Line type="monotone" dataKey="p1" name="Plate 1" stroke="#1D6FA5" dot={false} strokeWidth={2} />
                <Line type="monotone" dataKey="p2" name="Plate 2" stroke="#E8A318" dot={false} strokeWidth={2} />
                <Line type="monotone" dataKey="p3" name="Plate 3" stroke="#F0791F" dot={false} strokeWidth={2} />
                <Line type="monotone" dataKey="p4" name="Plate 4" stroke="#E23B3B" dot={false} strokeWidth={2} />
              </LineChart>
            </ResponsiveContainer>
          </div>
          <div className="vs-history-facts">
            <Field label="Current Position" value={patient.position} />
            <Field label="Current Risk" value={patient.risk} />
            <Field label="Time in Position" value={fmtDurationShort((Date.now() - patient.positionSince) / 1000)} />
          </div>
        </div>
      </div>
    </div>
  );
}

/* ---------------- Reports view ---------------- */
function ReportsView({ patients, onExport }) {
  const distribution = RISK_ORDER.map((r) => ({ name: r, value: patients.filter((p) => p.risk === r).length }));
  return (
    <div className="vs-panel">
      <div className="vs-panel-head"><h2>Reports</h2></div>
      <p className="vs-help-text">Generate a point-in-time snapshot report of all beds. Export as CSV now — PDF and Excel exports use the same dataset.</p>
      <div className="vs-report-actions">
        <button className="vs-btn vs-btn-primary" onClick={onExport}><Download size={14} /> Export CSV</button>
        <button className="vs-btn vs-btn-outline" onClick={onExport}><Download size={14} /> Export Excel (.csv)</button>
        <button className="vs-btn vs-btn-outline" onClick={() => window.print()}><Download size={14} /> Export PDF (print)</button>
      </div>
      <div className="vs-report-grid">
        {distribution.map((d) => (
          <div key={d.name} className="vs-report-tile">
            <span className="vs-report-tile-value">{d.value}</span>
            <span className="vs-report-tile-label">{d.name}</span>
          </div>
        ))}
      </div>
      <div className="vs-table-wrap">
        <table className="vs-table">
          <thead><tr><th>Bed</th><th>Patient</th><th>Ward</th><th>Avg Pressure</th><th>Risk</th></tr></thead>
          <tbody>
            {patients.map((p) => (
              <tr key={p.id}>
                <td className="vs-mono">#{p.bed}</td><td>{p.name}</td><td>{p.ward}</td>
                <td className="vs-mono">{Math.round(p.plates.reduce((a, b) => a + b, 0) / 4)}</td>
                <td><span className="vs-risk-pill" style={{ color: RISK_COLOR[p.risk].fg, background: RISK_COLOR[p.risk].bg }}>{p.risk}</span></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

/* ---------------- Analytics view ---------------- */
function AnalyticsView({ patients }) {
  const distribution = RISK_ORDER.map((r) => ({ name: r, value: patients.filter((p) => p.risk === r).length })).filter((d) => d.value > 0);
  const pieColors = { Normal: "#1F9D55", Medium: "#E8A318", High: "#F0791F", Critical: "#E23B3B" };
  const pressureByBed = patients.map((p) => ({ name: `Bed ${p.bed}`, avg: Math.round(p.plates.reduce((a, b) => a + b, 0) / 4) }));
  return (
    <div className="vs-panel">
      <div className="vs-panel-head"><h2>Analytics</h2></div>
      <div className="vs-analytics-grid">
        <div className="vs-chart-box">
          <h4>Risk Distribution</h4>
          <ResponsiveContainer width="100%" height={230}>
            <PieChart>
              <Pie data={distribution} dataKey="value" nameKey="name" outerRadius={80}
                label={{ fill: "var(--ink)", fontSize: 11 }}>
                {distribution.map((d, i) => <Cell key={i} fill={pieColors[d.name]} />)}
              </Pie>
              <Tooltip contentStyle={{ background: "var(--surface)", border: "1px solid var(--line)", borderRadius: 8, color: "var(--ink)" }} labelStyle={{ color: "var(--ink)" }} itemStyle={{ color: "var(--ink)" }} />
              <Legend wrapperStyle={{ fontSize: 11, color: "var(--ink)" }} />
            </PieChart>
          </ResponsiveContainer>
        </div>
        <div className="vs-chart-box">
          <h4>Average Pressure by Bed</h4>
          <ResponsiveContainer width="100%" height={230}>
            <BarChart data={pressureByBed}>
              <CartesianGrid strokeDasharray="3 3" stroke="var(--line)" />
              <XAxis dataKey="name" tick={{ fontSize: 10, fill: "var(--ink-soft)" }} />
              <YAxis tick={{ fontSize: 10, fill: "var(--ink-soft)" }} />
              <Tooltip contentStyle={{ background: "var(--surface)", border: "1px solid var(--line)", borderRadius: 8, color: "var(--ink)" }} labelStyle={{ color: "var(--ink)" }} itemStyle={{ color: "var(--ink)" }} />
              <Bar dataKey="avg" fill="#1D6FA5" radius={[4, 4, 0, 0]} />
            </BarChart>
          </ResponsiveContainer>
        </div>
      </div>
    </div>
  );
}

/* ---------------- Notifications view ---------------- */
function NotificationsView({ log }) {
  return (
    <div className="vs-panel">
      <div className="vs-panel-head"><h2>Notifications</h2></div>
      <div className="vs-log-list vs-log-list-static">
        {log.map((l) => (
          <div className="vs-log-item" key={l.id}>
            <span className="vs-log-time">{l.time.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" })}</span>
            {l.bed && <span className="vs-log-bed">Bed {l.bed}</span>}
            <span className="vs-log-text">{l.text}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

/* ---------------- Settings view ---------------- */
function SettingsView({ thresholds, setThresholds, dark, setDark, muted, setMuted, hospitalName, setHospitalName, pushToast }) {
  const [warnMin, setWarnMin] = useState(thresholds.warnMin);
  const [critMin, setCritMin] = useState(thresholds.critMin);
  const [name, setName] = useState(hospitalName);
  const [kioskMode, setKioskMode] = useState(null);
  const [kioskPassword, setKioskPassword] = useState("");
  const [kioskSaving, setKioskSaving] = useState(false);
  const [shutdownSaving, setShutdownSaving] = useState(false);

  useEffect(() => {
    fetch("http://127.0.0.1:3000/api/settings")
      .then((r) => r.json())
      .then((d) => setKioskMode(d.kiosk_mode))
      .catch(() => {});
  }, []);

  const saveKioskMode = async (nextValue) => {
    setKioskSaving(true);
    try {
      const res = await fetch("http://127.0.0.1:3000/api/settings/kiosk-mode", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ password: kioskPassword, kiosk_mode: nextValue }),
      });
      const data = await res.json();
      if (data.success) {
        setKioskMode(data.kiosk_mode);
        setKioskPassword("");
        pushToast(`Kiosk mode ${data.kiosk_mode ? "enabled" : "disabled"}`, "ok");
      } else {
        pushToast(data.error || "Incorrect password", "danger");
      }
    } catch (e) {
      pushToast("Could not reach backend", "danger");
    } finally {
      setKioskSaving(false);
    }
  };

  const requestShutdown = async () => {
    if (!window.confirm("Are you sure you want to close VitalS?")) return;

    setShutdownSaving(true);
    try {
      const res = await fetch("http://127.0.0.1:3010/api/shutdown", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
      });
      const data = await res.json();
      if (!data.success) throw new Error(data.error || "Shutdown request failed");
    } catch (e) {
      setShutdownSaving(false);
      pushToast("Could not shut down VitalS", "danger");
    }
  };


  return (
    <div className="vs-panel">
      <div className="vs-panel-head"><h2>Settings</h2></div>
      <div className="vs-settings-grid">
        <div className="vs-settings-card">
          <h4>Facility</h4>
          <label className="vs-field-label">Hospital Name</label>
          <input className="vs-input" value={name} onChange={(e) => setName(e.target.value)} />
        </div>
        <div className="vs-settings-card">
          <h4>Reposition Thresholds</h4>
          <label className="vs-field-label">Warning after (minutes)</label>
          <input className="vs-input" type="number" min={5} value={warnMin} onChange={(e) => setWarnMin(Number(e.target.value))} />
          <label className="vs-field-label">Critical after (minutes)</label>
          <input className="vs-input" type="number" min={10} value={critMin} onChange={(e) => setCritMin(Number(e.target.value))} />
        </div>
        <div className="vs-settings-card">
          <h4>Preferences</h4>
          <label className="vs-toggle-row"><input type="checkbox" checked={dark} onChange={(e) => setDark(e.target.checked)} /> Dark mode</label>
          <label className="vs-toggle-row"><input type="checkbox" checked={!muted} onChange={(e) => setMuted(!e.target.checked)} /> Alarm sound enabled</label>
        </div>
        <div className="vs-settings-card">
          <h4>Admin — Kiosk Mode</h4>
          <div style={{ fontSize: 12.5, marginBottom: 8, color: "var(--ink-soft)" }}>
            Currently: <strong>{kioskMode === null ? "Loading..." : kioskMode ? "Fullscreen (Kiosk)" : "Windowed"}</strong>
          </div>
          <label className="vs-field-label">Admin Password</label>
          <input
            className="vs-input"
            type="password"
            value={kioskPassword}
            onChange={(e) => setKioskPassword(e.target.value)}
            placeholder="Enter admin password"
          />
          <div style={{ display: "flex", gap: 8, marginTop: 4 }}>
            <button
              className="vs-btn vs-btn-primary"
              disabled={kioskSaving || !kioskPassword}
              onClick={() => saveKioskMode(true)}
            >
              Enable Kiosk Mode
            </button>
            <button
              className="vs-btn vs-btn-outline"
              disabled={kioskSaving || !kioskPassword}
              onClick={() => saveKioskMode(false)}
            >
              Disable Kiosk Mode
            </button>
          </div>
        </div>
      </div>
      <div
        className="vs-settings-card"
        style={{
          marginTop: 14,
          border: "1px solid rgba(220, 53, 69, 0.28)",
          background: "rgba(220, 53, 69, 0.045)",
        }}
      >
        <h4 style={{ color: "#c62828" }}>Application</h4>
        <div style={{ fontSize: 12.5, marginBottom: 10, color: "var(--ink-soft)" }}>
          Close the VitalS dashboard and cleanly stop its frontend and backend services.
        </div>
        <button
          className="vs-btn"
          disabled={shutdownSaving}
          onClick={requestShutdown}
          style={{
            background: "#c62828",
            color: "#fff",
            borderColor: "#c62828",
            boxShadow: "0 6px 16px rgba(198, 40, 40, 0.22)",
          }}
        >
          <Power size={14} />
          {shutdownSaving ? "Shutting down…" : "Shutdown VitalS"}
        </button>
      </div>

      <button className="vs-btn vs-btn-primary" onClick={() => {
        setThresholds({ warnMin, critMin });
        setHospitalName(name);
        pushToast("Settings saved", "ok");
      }}><Save size={14} /> Save Settings</button>
    </div>
  );
}

function Field({ label, value, valueStyle }) {
  return (
    <div className="vs-field">
      <span className="vs-field-label">{label}</span>
      <span className="vs-field-value" style={valueStyle}>{value}</span>
    </div>
  );
}

/* ---------------- Emergency modal ---------------- */
function EmergencyModal({ patient, onAcknowledge, onSilence }) {
  const secondsInPosition = (Date.now() - patient.positionSince) / 1000;
  const colors = RISK_COLOR[patient.risk];
  const actions = [
    `Reposition patient immediately`,
    `Turn patient to ${POSITIONS.filter((x) => x !== patient.position)[0]}`,
    `Reduce pressure on ${BODY_PART[patient.position].split(" /")[0]}`,
    `Inspect skin at pressure points`,
    `Use pressure-relieving cushion`,
    `Notify attending nurse`,
    `Reassess after repositioning`,
  ];
  return (
    <div className="vs-modal-backdrop">
      <div className="vs-modal vs-modal-in" style={{ "--ring": colors.ring }}>
        <div className="vs-modal-head">
          <div className="vs-modal-icon-wrap"><AlertTriangle size={26} className="vs-modal-warn-icon" /></div>
          <div>
            <div className="vs-modal-title">Emergency Alert — {patient.risk} Risk</div>
            <div className="vs-modal-sub">Detected {new Date().toLocaleTimeString()}</div>
          </div>
          <button className="vs-modal-close" onClick={onSilence}><X size={18} /></button>
        </div>
        <div className="vs-modal-grid">
          <Field label="Patient Name" value={patient.name} />
          <Field label="Patient ID" value={patient.patientId} />
          <Field label="Bed Number" value={`Bed ${patient.bed}`} />
          <Field label="Ward" value={patient.ward} />
          <Field label="Current Position" value={patient.position} />
          <Field label="Time in Position" value={fmtDuration(secondsInPosition)} />
          <Field label="Body Part at Risk" value={BODY_PART[patient.position]} />
          <Field label="Risk Level" value={patient.risk} valueStyle={{ color: colors.fg }} />
        </div>
        <div className="vs-modal-plates">
          {patient.plates.map((v, i) => (
            <div key={i} className="vs-modal-plate"><span>Plate {i + 1}</span><span className="vs-modal-plate-value">{v}</span></div>
          ))}
        </div>
        <div className="vs-modal-actions-title">Recommended Actions</div>
        <ul className="vs-modal-actions">{actions.map((a, i) => <li key={i}>{a}</li>)}</ul>
        <div className="vs-modal-buttons">
          <button className="vs-btn vs-btn-ghost" onClick={onSilence}>Silence Alarm</button>
          <button className="vs-btn vs-btn-outline">View Patient</button>
          <button className="vs-btn vs-btn-primary" onClick={onAcknowledge}><Check size={15} /> Acknowledge</button>
        </div>
      </div>
    </div>
  );
}

/* ---------------- 3D bed + patient modal (procedural Three.js) ---------------- */
function poseRotationFor(position) {
  switch (position) {
    case "Prone": return { x: Math.PI, tilt: 0 };
    case "Left Lateral": return { x: Math.PI / 2, tilt: 0 };
    case "Right Lateral": return { x: -Math.PI / 2, tilt: 0 };
    case "Sitting": return { x: 0, tilt: 0.55 };
    default: return { x: 0, tilt: 0 }; // Supine
  }
}

function Patient3DModal({ patient, onClose }) {
  const mountRef = useRef(null);
  const stateRef = useRef({});
  const patientRef = useRef(patient);
  patientRef.current = patient;

  useEffect(() => {
    const mount = mountRef.current;
    const width = mount.clientWidth, height = mount.clientHeight;

    const scene = new THREE.Scene();
    scene.background = new THREE.Color(0xeaf4fb);

    const camera = new THREE.PerspectiveCamera(45, width / height, 0.1, 100);
    let radius = 4.2, theta = 0.9, phi = 1.15;
    const target = new THREE.Vector3(0, 0.5, 0);
    const updateCam = () => {
      camera.position.set(
        target.x + radius * Math.sin(phi) * Math.sin(theta),
        target.y + radius * Math.cos(phi),
        target.z + radius * Math.sin(phi) * Math.cos(theta)
      );
      camera.lookAt(target);
    };
    updateCam();

    const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: false });
    renderer.setSize(width, height);
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    mount.appendChild(renderer.domElement);

    scene.add(new THREE.AmbientLight(0xffffff, 1.0));
    const dir = new THREE.DirectionalLight(0xffffff, 0.75);
    dir.position.set(3, 5, 2);
    scene.add(dir);

    const floor = new THREE.Mesh(
      new THREE.PlaneGeometry(20, 20),
      new THREE.MeshStandardMaterial({ color: 0xeef2f5, roughness: 0.9 })
    );
    floor.rotation.x = -Math.PI / 2;
    floor.position.y = -0.02;
    scene.add(floor);

    // faint floor tile lines, hospital-vinyl style
    const tileGrid = new THREE.GridHelper(20, 20, 0xd7e2ea, 0xe4edf3);
    tileGrid.position.y = -0.015;
    scene.add(tileGrid);

    // ---- Hospital room shell (walls / window / ceiling strip light) ----
    const roomGroup = new THREE.Group();
    const wallMat = new THREE.MeshStandardMaterial({ color: 0xdcf0f2, roughness: 0.9 });
    const wallTrimMat = new THREE.MeshStandardMaterial({ color: 0x9ecdd4, roughness: 0.75 });
    const roomW = 6.4, roomD = 5.4, roomH = 2.9;

    const backWall = new THREE.Mesh(new THREE.PlaneGeometry(roomW, roomH), wallMat);
    backWall.position.set(0, roomH / 2 - 0.02, -roomD / 2);
    roomGroup.add(backWall);

    const sideWallL = new THREE.Mesh(new THREE.PlaneGeometry(roomD, roomH), wallMat);
    sideWallL.rotation.y = Math.PI / 2;
    sideWallL.position.set(-roomW / 2, roomH / 2 - 0.02, 0);
    roomGroup.add(sideWallL);

    const sideWallR = sideWallL.clone();
    sideWallR.position.set(roomW / 2, roomH / 2 - 0.02, 0);
    sideWallR.rotation.y = -Math.PI / 2;
    roomGroup.add(sideWallR);

    // skirting / wainscot trim
    [backWall, sideWallL, sideWallR].forEach((w) => {
      const trim = new THREE.Mesh(new THREE.PlaneGeometry(w.geometry.parameters.width, 0.16), wallTrimMat);
      trim.position.copy(w.position);
      trim.position.y = 0.06;
      trim.rotation.copy(w.rotation);
      roomGroup.add(trim);
    });

    // window on the back wall with soft daylight glow
    const windowFrameMat = new THREE.MeshStandardMaterial({ color: 0xffffff });
    const windowFrame = new THREE.Mesh(new THREE.PlaneGeometry(1.7, 1.15), windowFrameMat);
    windowFrame.position.set(1.7, 1.85, -roomD / 2 + 0.01);
    roomGroup.add(windowFrame);
    const windowGlass = new THREE.Mesh(
      new THREE.PlaneGeometry(1.5, 0.95),
      new THREE.MeshStandardMaterial({ color: 0xbfe3f7, emissive: 0x9fd3f2, emissiveIntensity: 0.35 })
    );
    windowGlass.position.set(1.7, 1.85, -roomD / 2 + 0.02);
    roomGroup.add(windowGlass);
    const windowLight = new THREE.PointLight(0xcfeeff, 0.5, 6);
    windowLight.position.set(1.7, 1.85, -roomD / 2 + 1.2);
    roomGroup.add(windowLight);

    // ceiling strip light above the bed
    const ceilingLightMesh = new THREE.Mesh(
      new THREE.BoxGeometry(1.6, 0.05, 0.35),
      new THREE.MeshStandardMaterial({ color: 0xffffff, emissive: 0xffffff, emissiveIntensity: 0.9 })
    );
    ceilingLightMesh.position.set(-0.1, roomH - 0.05, 0);
    roomGroup.add(ceilingLightMesh);
    const ceilingLight = new THREE.PointLight(0xffffff, 0.6, 8);
    ceilingLight.position.set(-0.1, roomH - 0.2, 0);
    roomGroup.add(ceilingLight);

    // IV pole beside the bed
    const ivMat = new THREE.MeshStandardMaterial({ color: 0xc7d0d6, metalness: 0.6, roughness: 0.3 });
    const ivPole = new THREE.Group();
    const ivBase = new THREE.Mesh(new THREE.CylinderGeometry(0.22, 0.22, 0.03, 16), ivMat);
    ivBase.position.y = 0.015;
    ivPole.add(ivBase);
    const ivRod = new THREE.Mesh(new THREE.CylinderGeometry(0.018, 0.018, 1.55, 8), ivMat);
    ivRod.position.y = 0.79;
    ivPole.add(ivRod);
    const ivHook = new THREE.Mesh(new THREE.TorusGeometry(0.09, 0.012, 8, 16), ivMat);
    ivHook.rotation.x = Math.PI / 2;
    ivHook.position.y = 1.55;
    ivPole.add(ivHook);
    const ivBag = new THREE.Mesh(new THREE.SphereGeometry(0.09, 10, 10), new THREE.MeshStandardMaterial({ color: 0xdff3fb, transparent: true, opacity: 0.85 }));
    ivBag.scale.set(0.7, 1.2, 0.7);
    ivBag.position.y = 1.4;
    ivPole.add(ivBag);
    ivPole.position.set(-1.55, 0, 0.85);
    roomGroup.add(ivPole);

    // bedside vitals monitor stand
    const monitorMat = new THREE.MeshStandardMaterial({ color: 0x2c3a47, roughness: 0.4 });
    const monitorStand = new THREE.Group();
    const monitorCart = new THREE.Mesh(new THREE.BoxGeometry(0.34, 0.4, 0.3), new THREE.MeshStandardMaterial({ color: 0xe7ecef }));
    monitorCart.position.y = 0.6;
    monitorStand.add(monitorCart);
    const monitorPole = new THREE.Mesh(new THREE.CylinderGeometry(0.02, 0.02, 0.5, 8), monitorMat);
    monitorPole.position.y = 1.05;
    monitorStand.add(monitorPole);
    const monitorScreen = new THREE.Mesh(
      new THREE.BoxGeometry(0.32, 0.22, 0.03),
      new THREE.MeshStandardMaterial({ color: 0x0d1b2a, emissive: 0x1f9d55, emissiveIntensity: 0.35 })
    );
    monitorScreen.position.y = 1.32;
    monitorStand.add(monitorScreen);
    monitorStand.position.set(-1.55, 0, -0.9);
    roomGroup.add(monitorStand);

    scene.add(roomGroup);

    // ---- Bed ----
    const bedGroup = new THREE.Group();
    let mattressTopY = 0.62; // where the patient/plates sit; recalculated if a custom bed model loads

    // procedural fallback bed lives in its own subgroup so it can be hidden
    // independently if/when a custom bed model loads successfully
    const proceduralBed = new THREE.Group();
    bedGroup.add(proceduralBed);

    const frameMat = new THREE.MeshStandardMaterial({ color: 0xb9c4cd, metalness: 0.4, roughness: 0.5 });
    const frame = new THREE.Mesh(new THREE.BoxGeometry(2.2, 0.12, 1.0), frameMat);
    frame.position.y = 0.42;
    proceduralBed.add(frame);
    [[-1.0, -0.42], [1.0, -0.42], [-1.0, 0.42], [1.0, 0.42]].forEach(([x, z]) => {
      const leg = new THREE.Mesh(new THREE.CylinderGeometry(0.04, 0.04, 0.42, 8), frameMat);
      leg.position.set(x, 0.21, z);
      proceduralBed.add(leg);
    });
    const mattress = new THREE.Mesh(
      new THREE.BoxGeometry(2.05, 0.14, 0.9),
      new THREE.MeshStandardMaterial({ color: 0xf4f8fb, roughness: 0.9 })
    );
    mattress.position.y = 0.55;
    proceduralBed.add(mattress);
    const headboard = new THREE.Mesh(new THREE.BoxGeometry(0.06, 0.55, 1.0), frameMat);
    headboard.position.set(-1.1, 0.7, 0);
    proceduralBed.add(headboard);
    scene.add(bedGroup);

    // ---- Optional: load the user's own bed model (./models/hospital_bed.glb) ----
    // Replaces the procedural bed frame/mattress/headboard above (which is hidden)
    // but stays inside bedGroup, so the plates, the patient, and every pose/
    // position calculation below sit on it exactly as they did on the procedural bed.
    const customBedHolder = new THREE.Group();
    bedGroup.add(customBedHolder);
    const bedLoader = new GLTFLoader();
    bedLoader.load(
      BED_MODEL_PATH,
      (gltf) => {
        console.info(`[VitalS] Loaded custom bed model from ${BED_MODEL_PATH}`);
        proceduralBed.visible = false; // hide procedural fallback bed
        const model = gltf.scene;
        const box = new THREE.Box3().setFromObject(model);
        const size = new THREE.Vector3();
        box.getSize(size);
        const targetLength = 2.2; // matches the procedural bed's frame length
        const largestHoriz = Math.max(size.x, size.z) || 1;
        const scale = targetLength / largestHoriz;
        model.scale.setScalar(scale);
        model.updateMatrixWorld(true);

        // Make sure the bed's length lines up with world X — the axis the
        // plates and patient are placed along — regardless of which way the
        // source file's long axis happens to run. (This was the actual cause
        // of the bed looking rotated relative to the patient/plates.)
        let orientBox = new THREE.Box3().setFromObject(model);
        let orientSize = new THREE.Vector3();
        orientBox.getSize(orientSize);
        if (orientSize.z > orientSize.x) {
          model.rotateY(Math.PI / 2);
          model.updateMatrixWorld(true);
        }

        // Recompute the scaled bounding box to sit the model on the floor,
        // centered under the bed group, and read off its top (mattress) height.
        const scaledBox = new THREE.Box3().setFromObject(model);
        const center = new THREE.Vector3();
        scaledBox.getCenter(center);
        model.position.x -= center.x;
        model.position.z -= center.z;
        model.position.y -= scaledBox.min.y; // rest on the floor (y = 0)

        const finalBox = new THREE.Box3().setFromObject(model);
        mattressTopY = finalBox.max.y - 0.08; // slight inset so the body doesn't float above the mattress

        customBedHolder.add(model);

        // Re-seat the plates and the patient pivot onto the new bed's mattress height.
        plateMeshes.forEach((mesh) => { mesh.position.y = mattressTopY + 0.015; });
        bodyPivot.position.y = mattressTopY;
      },
      undefined,
      (err) => {
        // No custom bed model found (or it failed to parse) — keep the built-in procedural bed.
        console.warn(`[VitalS] Could not load bed model at ${BED_MODEL_PATH}. Falling back to the built-in bed. Error:`, err);
      }
    );

    // ---- Plate zones (positioned along bed length) ----
    const plateX = [-0.75, -0.2, 0.35, 0.85];
    const plateMeshes = [];
    plateX.forEach((x) => {
      const geo = new THREE.BoxGeometry(0.42, 0.03, 0.7);
      const mat = new THREE.MeshStandardMaterial({ color: 0x1f9d55, emissive: 0x1f9d55, emissiveIntensity: 0.4 });
      const mesh = new THREE.Mesh(geo, mat);
      mesh.position.set(x, mattressTopY + 0.015, 0);
      bedGroup.add(mesh);
      plateMeshes.push(mesh);
    });

    // ---- Patient body (procedural) ----
    const bodyPivot = new THREE.Group();
    bodyPivot.position.set(0, mattressTopY, 0);
    bedGroup.add(bodyPivot);

    const bodyGroup = new THREE.Group();
    bodyPivot.add(bodyGroup);

    const gownMat = new THREE.MeshStandardMaterial({ color: 0x6fa8d8, roughness: 0.85 });
    const skinMat = new THREE.MeshStandardMaterial({ color: 0xe3b28c, roughness: 0.8 });

    // procedural fallback figure lives in its own subgroup so it can be hidden
    // independently if/when a custom model loads successfully
    const proceduralBody = new THREE.Group();
    bodyGroup.add(proceduralBody);

    const torso = new THREE.Mesh(new THREE.CylinderGeometry(0.16, 0.2, 0.85, 16), gownMat);
    torso.rotation.z = Math.PI / 2;
    torso.position.set(0.05, 0.1, 0);
    proceduralBody.add(torso);

    const head = new THREE.Mesh(new THREE.SphereGeometry(0.115, 16, 16), skinMat);
    head.position.set(-0.55, 0.1, 0);
    proceduralBody.add(head);

    const legMat = gownMat;
    const legL = new THREE.Mesh(new THREE.CylinderGeometry(0.09, 0.06, 0.75, 12), legMat);
    legL.rotation.z = Math.PI / 2;
    legL.position.set(0.85, 0.1, 0.12);
    proceduralBody.add(legL);
    const legR = legL.clone();
    legR.position.z = -0.12;
    proceduralBody.add(legR);

    const footL = new THREE.Mesh(new THREE.SphereGeometry(0.07, 10, 10), skinMat);
    footL.position.set(1.25, 0.1, 0.12);
    proceduralBody.add(footL);
    const footR = footL.clone();
    footR.position.z = -0.12;
    proceduralBody.add(footR);

    const armL = new THREE.Mesh(new THREE.CylinderGeometry(0.05, 0.045, 0.6, 10), gownMat);
    armL.rotation.z = Math.PI / 2;
    armL.position.set(0.1, 0.04, 0.24);
    proceduralBody.add(armL);
    const armR = armL.clone(); armR.position.z = -0.24; proceduralBody.add(armR);

    // ---- Optional: load the user's own patient model (./models/patient.glb) ----
    // If present, it replaces the procedural figure above (which is hidden) but
    // still lives inside the same bodyGroup, so it inherits the exact same
    // position on the mattress and the exact same pose/rotation logic below.
    const customModelHolder = new THREE.Group();
    bodyGroup.add(customModelHolder);
    const gltfLoader = new GLTFLoader();
    if (USE_CUSTOM_PATIENT_MODEL) gltfLoader.load(
      CUSTOM_MODEL_PATH,
      (gltf) => {
        console.info(`[VitalS] Loaded custom patient model from ${CUSTOM_MODEL_PATH}`);
        proceduralBody.visible = false; // hide procedural fallback figure
        const model = gltf.scene;

        // Most patient/character models are exported standing upright (Y = height,
        // Z = facing forward). Lay the model down onto its back so it matches the
        // bed's supine layout: head-to-toe -> X axis (matching the plate order
        // Shoulders→Mid-Back→Hips→Heels), and the model's front -> +Y (face up).
        // Verified against this model's actual vertex data: head sits at high Y,
        // feet near Y=0, and the feet/toes point toward +Z (front-facing).
        const layFlat = new THREE.Matrix4().set(
          0, -1, 0, 0,
          0, 0, 1, 0,
          -1, 0, 0, 0,
          0, 0, 0, 1
        );
        model.quaternion.setFromRotationMatrix(layFlat);
        model.updateMatrixWorld(true);

        // Safety net for other/future models: if a differently-authored model
        // doesn't land with its length along X, self-correct with a 90° turn.
        // (This mesh, verified above, shouldn't need it.)
        let box = new THREE.Box3().setFromObject(model);
        let size = new THREE.Vector3();
        box.getSize(size);
        if (size.z > size.x) {
          model.rotateY(Math.PI / 2);
          model.updateMatrixWorld(true);
        }

        // Normalize scale using the *actual measured* body length (the larger
        // of the two horizontal dimensions) so it always fits the mattress,
        // regardless of how the source model was originally sized.
        box = new THREE.Box3().setFromObject(model);
        box.getSize(size);
        const targetLength = 1.9; // roughly a body's length in scene units, matched to the mattress
        const bodyLength = Math.max(size.x, size.z);
        const scale = targetLength / (bodyLength || 1);
        model.scale.multiplyScalar(scale);
        model.updateMatrixWorld(true);

        const finalBox = new THREE.Box3().setFromObject(model);
        const center = new THREE.Vector3();
        finalBox.getCenter(center);
        model.position.x -= center.x;
        model.position.z -= center.z;
        model.position.y -= finalBox.min.y; // rest on the mattress (y = 0 in this local space)

        customModelHolder.add(model);
      },
      undefined,
      (err) => {
        // No custom model found (or it failed to parse) — keep the built-in procedural figure.
        console.warn(`[VitalS] Could not load patient model at ${CUSTOM_MODEL_PATH}. Falling back to the built-in figure. Error:`, err);
      }
    );

    // text sprite helper
    function makeSprite(text, bg) {
      const canvas = document.createElement("canvas");
      canvas.width = 220; canvas.height = 80;
      const ctx = canvas.getContext("2d");
      ctx.fillStyle = bg; ctx.roundRect ? (ctx.roundRect(0, 0, 220, 80, 14), ctx.fill()) : ctx.fillRect(0, 0, 220, 80);
      ctx.fillStyle = "#0d1b2a";
      ctx.font = "bold 26px Inter, sans-serif";
      ctx.textAlign = "center";
      ctx.fillText(text, 110, 48);
      const tex = new THREE.CanvasTexture(canvas);
      const mat = new THREE.SpriteMaterial({ map: tex, transparent: true });
      const sprite = new THREE.Sprite(mat);
      sprite.scale.set(0.5, 0.18, 1);
      return { sprite, canvas, ctx, tex };
    }
    // Value labels sit beside the bed (offset on Z, the bed's width axis)
    // rather than hovering directly above the patient, so they never overlap
    // the body or the mattress.
    const spriteSideZ = 0.85;
    const sprites = plateX.map((x, i) => {
      const s = makeSprite(`P${i + 1}: --`, "#ffffff");
      s.sprite.position.set(x, mattressTopY + 0.35, spriteSideZ);
      scene.add(s.sprite);
      return s;
    });
    function updateSprite(s, label, value, colorCss) {
      const { ctx, canvas, tex } = s;
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      ctx.fillStyle = "#ffffff";
      ctx.beginPath();
      ctx.roundRect ? ctx.roundRect(0, 0, 220, 80, 16) : ctx.rect(0, 0, 220, 80);
      ctx.fill();
      ctx.fillStyle = colorCss;
      ctx.fillRect(0, 0, 8, 80);
      ctx.fillStyle = "#0d1b2a";
      ctx.font = "600 16px Inter, sans-serif";
      ctx.textAlign = "left";
      ctx.fillText(label, 18, 30);
      ctx.font = "800 26px Inter, sans-serif";
      ctx.fillStyle = colorCss;
      ctx.fillText(String(value), 18, 62);
      tex.needsUpdate = true;
    }

    // pose — the patient model always stays laid flat on its back (Supine),
    // fixed in place along the bed. It no longer re-postures itself when the
    // patient's clinical "position" value changes; that value is still shown
    // as text (bed card, footer, side panel) but doesn't move the 3D figure.
    function applyPose() {
      bodyGroup.rotation.x = 0;
      bodyPivot.rotation.z = 0;
      bodyPivot.position.y = mattressTopY;
    }
    applyPose();

    // interaction: manual drag-orbit (OrbitControls unavailable in this three build)
    let dragging = false, lastX = 0, lastY = 0;
    const dom = renderer.domElement;
    const onDown = (e) => { dragging = true; lastX = e.clientX; lastY = e.clientY; };
    const onMove = (e) => {
      if (!dragging) return;
      const dx = e.clientX - lastX, dy = e.clientY - lastY;
      lastX = e.clientX; lastY = e.clientY;
      theta -= dx * 0.006;
      phi = Math.max(0.35, Math.min(1.5, phi - dy * 0.006));
      updateCam();
    };
    const onUp = () => { dragging = false; };
    const onWheel = (e) => {
      e.preventDefault();
      radius = Math.max(2.2, Math.min(7, radius + e.deltaY * 0.0025));
      updateCam();
    };
    dom.addEventListener("pointerdown", onDown);
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
    dom.addEventListener("wheel", onWheel, { passive: false });

    let raf;
    let autoSpin = 0;
    const animate = () => {
      const p = patientRef.current;
      if (!dragging) { autoSpin += 0.0015; theta += autoSpin * 0; }
      p.plates.forEach((v, i) => {
        const hex = valueToColorHex(v);
        plateMeshes[i].material.color.setHex(hex);
        plateMeshes[i].material.emissive.setHex(hex);
        const pulse = v > 700 ? 0.55 + Math.sin(Date.now() / 220) * 0.25 : 0.35;
        plateMeshes[i].material.emissiveIntensity = pulse;
        plateMeshes[i].scale.y = 1 + Math.max(0, (v - 400)) / 900;
        updateSprite(sprites[i], PLATE_ZONE[i], v, hexToCss(hex));
      });
      renderer.render(scene, camera);
      raf = requestAnimationFrame(animate);
    };
    animate();

    const onResize = () => {
      const w = mount.clientWidth, h = mount.clientHeight;
      camera.aspect = w / h; camera.updateProjectionMatrix();
      renderer.setSize(w, h);
    };
    window.addEventListener("resize", onResize);

    stateRef.current = { renderer, scene };

    return () => {
      cancelAnimationFrame(raf);
      dom.removeEventListener("pointerdown", onDown);
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);
      dom.removeEventListener("wheel", onWheel);
      window.removeEventListener("resize", onResize);
      scene.traverse((obj) => {
        if (obj.geometry) obj.geometry.dispose();
        if (obj.material) {
          if (obj.material.map) obj.material.map.dispose();
          obj.material.dispose();
        }
      });
      renderer.dispose();
      if (mount.contains(renderer.domElement)) mount.removeChild(renderer.domElement);
    };
  }, []);

  const colors = RISK_COLOR[patient.risk];
  const secondsInPosition = (Date.now() - patient.positionSince) / 1000;

  return (
    <div className="vs-modal-backdrop" onDoubleClick={onClose}>
      <div className="vs-modal vs-modal-in vs-modal-3d" style={{ "--ring": colors.ring }} onDoubleClick={(e) => e.stopPropagation()}>
        <div className="vs-modal-head">
          <div className="vs-modal-icon-wrap" style={{ background: "rgba(29,111,165,0.1)", color: "#1D6FA5" }}>
            <RotateCw size={22} />
          </div>
          <div>
            <div className="vs-modal-title">Bed {patient.bed} — 3D Pressure View</div>
            <div className="vs-modal-sub">Drag to rotate • Scroll to zoom</div>
          </div>
          <button className="vs-modal-close" onClick={onClose}><X size={18} /></button>
        </div>
        <div className="vs-3d-layout">
          <div className="vs-3d-canvas" ref={mountRef}></div>
          <div className="vs-3d-side">
            <div className="vs-risk-pill vs-3d-risk" style={{ color: colors.fg, background: colors.bg }}>{patient.risk} Risk</div>
            <Field label="Patient Name" value={patient.name} />
            <Field label="Patient ID" value={patient.patientId} />
            <Field label="Age / Gender" value={`${patient.age} / ${patient.gender}`} />
            <Field label="Ward" value={patient.ward} />
            <Field label="Bed Number" value={`Bed ${patient.bed}`} />
            <Field label="Position" value={patient.position} />
            <Field label="Time in Position" value={fmtDurationShort(secondsInPosition)} />
            <Field label="Body Part at Risk" value={BODY_PART[patient.position]} />
            <div className="vs-3d-plate-list">
              {patient.plates.map((v, i) => (
                <div key={i} className="vs-3d-plate-row">
                  <span>{PLATE_ZONE[i]}</span>
                  <span className="vs-mono" style={{ color: hexToCss(valueToColorHex(v)), fontWeight: 700 }}>{v}</span>
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

const CSS = `
:root{
  --bg:#F3F6F9; --surface:#FFFFFF; --surface-2:#F3F6F9; --ink:#16253B; --ink-soft:#5B6B80;
  --medblue:#1D6FA5; --medblue-deep:#154F7A; --line:#E3E9EF;
  --ok:#1F9D55; --warn:#E8A318; --high:#F0791F; --crit:#E23B3B;
  --sky:#EAF6FF; --sky-deep:#D5ECFB;
  --risk-normal-fg:#1F9D55; --risk-normal-bg:#E7F7ED; --risk-normal-ring:rgba(31,157,85,0.35);
  --risk-medium-fg:#B8860B; --risk-medium-bg:#FDF3D8; --risk-medium-ring:rgba(232,163,24,0.4);
  --risk-high-fg:#C05A12; --risk-high-bg:#FDE9D9; --risk-high-ring:rgba(240,121,31,0.45);
  --risk-crit-fg:#C42B2B; --risk-crit-bg:#FBE2E2; --risk-crit-ring:rgba(226,59,59,0.55);
  --font-main:'Inter','Segoe UI',Roboto,-apple-system,sans-serif;
  --warn-toast:#B8860B;
  --nav-ink:#1c4a68;
}
.vs-root{ font-family:var(--font-main); background:var(--bg); color:var(--ink); min-height:100vh; width:100%; transition:background .3s,color .3s; }
.vs-dark{
  /* True black / neutral-grey surfaces (no navy tint), matching the reference look */
  --bg:#0A0A0C; --surface:#18181B; --surface-2:#212124; --ink:#F5F6F7; --ink-soft:#9CA0A8; --line:#2E2F33;
  --sky:#111113; --sky-deep:#08080A;
  /* Slightly brighter blue accent so it still pops on near-black surfaces */
  --medblue:#4FA8E8; --medblue-deep:#2E86D6;
  /* Brighter, higher-contrast status colors so indicators read clearly on black/grey */
  --ok:#3DDC8A; --warn:#FBBF24; --high:#FB923C; --crit:#FF6B6B;
  --risk-normal-fg:#3DDC8A; --risk-normal-bg:rgba(61,220,138,0.16);
  --risk-medium-fg:#FBBF24; --risk-medium-bg:rgba(251,191,36,0.16);
  --risk-high-fg:#FB923C; --risk-high-bg:rgba(251,146,60,0.16);
  --risk-crit-fg:#FF6B6B; --risk-crit-bg:rgba(255,107,107,0.18);
  --warn-toast:#FBBF24;
  --nav-ink:#C4CAD3;
}
.vs-root *{ box-sizing:border-box; font-family:var(--font-main); }

@keyframes vsFadeSlide{ from{opacity:0; transform:translateY(10px);} to{opacity:1; transform:translateY(0);} }
@keyframes vsBreathe{ 0%,100%{ box-shadow:0 0 0 0 var(--risk-ring);} 50%{ box-shadow:0 0 0 6px var(--risk-ring);} }
@keyframes vsPulseWarn{ 0%,100%{ box-shadow:0 0 0 0 var(--risk-ring);} 50%{ box-shadow:0 0 0 8px var(--risk-ring);} }
@keyframes vsPulseHigh{ 0%,100%{ box-shadow:0 0 0 0 var(--risk-ring); transform:scale(1);} 50%{ box-shadow:0 0 0 11px var(--risk-ring); transform:scale(1.004);} }
@keyframes vsHeartbeat{ 0%,100%{ box-shadow:0 0 0 0 var(--risk-ring); transform:scale(1);} 15%{ transform:scale(1.012);} 30%{ transform:scale(1);} 45%{ transform:scale(1.02); box-shadow:0 0 22px 4px var(--risk-ring);} 60%{ transform:scale(1);} }
@keyframes vsShake{ 0%,100%{transform:translateX(0);} 25%{transform:translateX(-2px);} 75%{transform:translateX(2px);} }
@keyframes vsToastIn{ from{opacity:0; transform:translateX(30px);} to{opacity:1; transform:translateX(0);} }
@keyframes vsModalIn{ from{opacity:0; transform:translateY(16px) scale(.97);} to{opacity:1; transform:translateY(0) scale(1);} }
@keyframes vsWarnIcon{ 0%,100%{transform:rotate(0);} 20%{transform:rotate(-8deg);} 40%{transform:rotate(8deg);} 60%{transform:rotate(-4deg);} 80%{transform:rotate(4deg);} }

.vs-card-appear{ animation:vsFadeSlide .5s ease both; }
.vs-stat-appear{ animation:vsFadeSlide .45s ease both; }

.vs-header{ position:sticky; top:0; z-index:30; display:flex; align-items:center; justify-content:space-between;
  gap:16px; padding:10px 20px; background:var(--surface); border-bottom:1px solid var(--line);
  box-shadow:0 1px 3px rgba(16,37,59,0.05); transition:box-shadow .4s; }
.vs-header-emergency{ box-shadow:0 0 0 2px var(--crit), 0 4px 18px rgba(226,59,59,0.25); }
.vs-header-left{ display:flex; align-items:center; gap:10px; }
.vs-brand{ display:flex; align-items:center; gap:10px; }
.vs-brand-mark{ width:38px; height:38px; border-radius:10px; background:linear-gradient(135deg,var(--medblue),var(--medblue-deep));
  color:#ff8686; display:flex; align-items:center; justify-content:center; box-shadow:0 3px 8px rgba(29,111,165,0.35); }
.vs-brand-text{ display:flex; flex-direction:column; line-height:1.15; }
.vs-brand-name{ font-weight:800; font-size:20px; letter-spacing:.2px; }
.vs-brand-sub{ font-size:10.5px; color:var(--ink-soft); font-weight:500; max-width:260px; }
.vs-header-mid{ display:none; align-items:center; gap:10px; font-size:13px; color:var(--ink-soft); }
.vs-hospital-name{ font-weight:600; color:var(--ink); }
.vs-dot{ opacity:.5; }
@media(min-width:1180px){ .vs-header-mid{ display:flex; } }
.vs-header-right{ display:flex; align-items:center; gap:8px; position:relative; }
.vs-mqtt{ display:flex; align-items:center; gap:6px; font-size:12px; font-weight:600; padding:6px 10px; border-radius:20px; }
.vs-mqtt.ok{ color:var(--ok); background:rgba(31,157,85,0.1); }
.vs-mqtt.down{ color:var(--crit); background:rgba(226,59,59,0.1); }
.vs-active-count{ display:none; align-items:center; gap:6px; font-size:12px; font-weight:600; color:var(--medblue); background:rgba(29,111,165,0.08); padding:6px 10px; border-radius:20px; }
@media(min-width:900px){ .vs-active-count{ display:flex; } }
.vs-icon-btn{ position:relative; width:34px; height:34px; border-radius:9px; border:1px solid var(--line); background:var(--surface);
  color:var(--ink-soft); display:flex; align-items:center; justify-content:center; cursor:pointer; transition:all .18s; }
.vs-icon-btn:hover{ background:var(--bg); color:var(--medblue); transform:translateY(-1px); }
.vs-only-mobile{ display:flex; }
@media(min-width:860px){ .vs-only-mobile{ display:none; } }
.vs-badge{ position:absolute; top:-4px; right:-4px; background:var(--crit); color:#fff; font-size:10px; font-weight:700;
  min-width:16px; height:16px; border-radius:8px; display:flex; align-items:center; justify-content:center; padding:0 3px; }
.vs-profile{ display:none; align-items:center; gap:8px; padding-left:8px; border-left:1px solid var(--line); margin-left:4px; }
@media(min-width:1000px){ .vs-profile{ display:flex; } }
.vs-avatar{ width:32px; height:32px; border-radius:50%; background:linear-gradient(135deg,#4E9CC9,#1D6FA5); color:#fff;
  display:flex; align-items:center; justify-content:center; font-size:12px; font-weight:700; }
.vs-profile-text{ display:flex; flex-direction:column; line-height:1.2; }
.vs-profile-name{ font-size:12.5px; font-weight:700; }
.vs-profile-dept{ font-size:10.5px; color:var(--ink-soft); }
.vs-notif-pop{ position:absolute; top:44px; right:70px; width:280px; background:var(--surface); border:1px solid var(--line);
  border-radius:12px; box-shadow:0 12px 30px rgba(16,37,59,0.15); animation:vsFadeSlide .18s ease; overflow:hidden; z-index:40; }
.vs-notif-head{ padding:10px 14px; font-weight:700; font-size:13px; border-bottom:1px solid var(--line); }
.vs-notif-list{ max-height:260px; overflow-y:auto; }
.vs-notif-item{ padding:9px 14px; font-size:12px; border-bottom:1px solid var(--line); display:flex; gap:8px; color:var(--ink-soft); }
.vs-notif-time{ font-size:10.5px; white-space:nowrap; color:var(--medblue); font-weight:600; }
.vs-notif-viewall{ width:100%; padding:9px; background:var(--bg); border:none; border-top:1px solid var(--line); color:var(--medblue); font-weight:700; font-size:12px; cursor:pointer; }

.vs-body{ display:flex; align-items:stretch; }
.vs-sidebar{ width:216px; flex-shrink:0; background:linear-gradient(180deg,var(--sky),var(--sky-deep)); border-right:1px solid var(--line);
  min-height:calc(100vh - 60px); padding:14px 10px; position:sticky; top:60px; transition:width .28s ease; display:flex; flex-direction:column; justify-content:space-between; }
.vs-sidebar.vs-collapsed{ width:64px; }
.vs-nav-list{ display:flex; flex-direction:column; gap:3px; }
.vs-nav-item{ position:relative; display:flex; align-items:center; gap:11px; padding:10px 12px; border-radius:10px; border:none;
  background:transparent; color:var(--nav-ink); font-size:13.5px; font-weight:600; cursor:pointer; text-align:left;
  transition:color .18s; overflow:hidden; }
.vs-nav-item:hover{ color:var(--medblue-deep); }
.vs-nav-label{ position:relative; z-index:1; white-space:nowrap; flex:1; }
.vs-nav-item svg{ position:relative; z-index:1; flex-shrink:0; }
.vs-nav-highlight{ position:absolute; inset:0; background:linear-gradient(135deg,rgba(29,111,165,0.22),rgba(29,111,165,0.05));
  transform:scaleX(0); transform-origin:left; transition:transform .28s ease; border-radius:10px; }
.vs-nav-active{ color:var(--medblue-deep); }
.vs-nav-active .vs-nav-highlight{ transform:scaleX(1); }
.vs-nav-active::before{ content:''; position:absolute; left:0; top:6px; bottom:6px; width:3px; background:var(--medblue-deep); border-radius:3px; }
.vs-nav-count{ position:relative; z-index:1; background:var(--medblue-deep); color:#fff; font-size:10px; font-weight:700; padding:1px 6px; border-radius:10px; }
.vs-sidebar-collapse{ display:flex; align-items:center; gap:6px; justify-content:center; padding:9px; border-radius:9px; border:1px solid rgba(29,111,165,0.25);
  background:rgba(255,255,255,0.4); color:var(--nav-ink); font-size:12px; font-weight:600; cursor:pointer; }
.vs-dark .vs-sidebar-collapse{ background:rgba(255,255,255,0.06); border-color:rgba(79,168,232,0.3); }

.vs-main{ flex:1; padding:20px 22px 40px; min-width:0; }
.vs-emergency-banner{ display:flex; align-items:center; gap:8px; background:var(--crit); color:#fff; font-weight:700;
  font-size:13px; padding:9px 14px; border-radius:10px; margin-bottom:16px; letter-spacing:.3px; animation:vsFadeSlide .3s ease; }

.vs-summary{ display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:12px; margin-bottom:20px; }
.vs-stat-card{ background:var(--surface); border:1px solid var(--line); border-radius:14px; padding:14px; display:flex;
  align-items:center; gap:12px; box-shadow:0 1px 2px rgba(16,37,59,0.04); }
.vs-stat-icon{ width:38px; height:38px; border-radius:10px; display:flex; align-items:center; justify-content:center; flex-shrink:0; }
.vs-tone-blue{ background:rgba(29,111,165,0.1); color:var(--medblue); }
.vs-tone-ok{ background:rgba(31,157,85,0.1); color:var(--ok); }
.vs-tone-warn{ background:rgba(232,163,24,0.12); color:var(--warn); }
.vs-tone-crit{ background:rgba(226,59,59,0.1); color:var(--crit); }
.vs-stat-text{ display:flex; flex-direction:column; min-width:0; }
.vs-stat-value{ font-weight:800; font-size:19px; line-height:1.1; }
.vs-stat-label{ font-size:11px; color:var(--ink-soft); font-weight:600; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }

.vs-grid{ display:grid; grid-template-columns:repeat(auto-fill,minmax(280px,1fr)); gap:14px; margin-bottom:22px; }
@media(min-width:1500px){ .vs-grid{ grid-template-columns:repeat(4,1fr); } }

.vs-dash-wrap{ background:var(--sky); border-radius:18px; padding:16px; }
.vs-filter-bar{ display:flex; align-items:center; gap:10px; flex-wrap:wrap; margin-bottom:14px; }
.vs-filter-label{ font-size:12px; font-weight:700; color:var(--ink-soft); display:flex; align-items:center; gap:6px; }
.vs-filter-select{ -webkit-appearance:none; appearance:none; border:1px solid var(--line); background-color:var(--surface); color:var(--ink); font-size:12.5px; font-weight:600; padding:7px 26px 7px 10px; border-radius:9px; outline:none; cursor:pointer;
  background-image:url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%235B6B80' stroke-width='2'><path d='M6 9l6 6 6-6'/></svg>");
  background-repeat:no-repeat; background-position:right 8px center; background-size:14px; }
.vs-filter-select option{ background:var(--surface); color:var(--ink); }
.vs-filter-reset{ border:1px solid var(--line); background:var(--surface); color:var(--medblue); font-size:12px; font-weight:700; padding:7px 12px; border-radius:9px; cursor:pointer; }
.vs-bed-card{ position:relative; background:var(--surface); border:1px solid var(--line); border-radius:16px; padding:14px 15px;
  transition:transform .22s ease, box-shadow .22s ease; cursor:default; }
.vs-bed-card:hover{ transform:translateY(-3px) scale(1.012); box-shadow:0 14px 28px rgba(16,37,59,0.12); }
.vs-pulse-normal{ animation:vsBreathe 3.6s ease-in-out infinite; }
.vs-pulse-medium{ animation:vsPulseWarn 2.4s ease-in-out infinite; }
.vs-pulse-high{ animation:vsPulseHigh 1.5s ease-in-out infinite; border-color:var(--high); }
.vs-pulse-critical{ animation:vsHeartbeat 1.1s ease-in-out infinite, vsShake 6s ease-in-out infinite; border-color:var(--crit); }

.vs-bed-top{ display:flex; align-items:center; justify-content:space-between; margin-bottom:10px; }
.vs-bed-id{ display:flex; align-items:center; gap:7px; }
.vs-status-dot{ width:11px; height:11px; border-radius:50%; flex-shrink:0; }
.vs-dot-normal, .vs-dot-low{ background:var(--ok); }
.vs-dot-medium{ background:var(--warn); }
.vs-dot-high{ background:var(--high); }
.vs-dot-critical{ background:var(--crit); }
.vs-bed-num{ font-weight:800; font-size:14.5px; }
.vs-ward{ font-size:11px; color:var(--ink-soft); background:var(--bg); padding:2px 7px; border-radius:6px; font-weight:600; }
.vs-risk-pill{ font-size:11px; font-weight:700; padding:4px 10px; border-radius:20px; transition:all .3s; }

.vs-patient-info{ margin-bottom:10px; }
.vs-patient-name{ font-weight:700; font-size:14.5px; }
.vs-patient-meta{ font-size:11.5px; color:var(--ink-soft); }

.vs-position-row{ display:flex; align-items:center; justify-content:space-between; margin-bottom:8px; }
.vs-position{ display:flex; align-items:center; gap:6px; font-weight:600; font-size:13px; }
.vs-repo-badge{ font-size:10px; font-weight:700; padding:3px 8px; border-radius:8px; }
.vs-repo-badge.vs-tone-ok{ background:rgba(31,157,85,0.1); color:var(--ok); }
.vs-repo-badge.vs-tone-warn{ background:rgba(232,163,24,0.14); color:var(--warn); }
.vs-repo-badge.vs-tone-crit{ background:rgba(226,59,59,0.12); color:var(--crit); }

.vs-timer{ display:flex; align-items:center; gap:6px; font-size:12.5px; font-weight:700;
  color:var(--medblue); background:rgba(29,111,165,0.06); padding:6px 10px; border-radius:8px; margin-bottom:10px; }

.vs-plates{ display:grid; grid-template-columns:1fr 1fr; gap:8px; margin-bottom:10px; }
.vs-plate{ background:var(--surface-2); border:1px solid var(--line); border-radius:10px; padding:7px 9px; }
.vs-plate-head{ display:flex; align-items:center; justify-content:space-between; font-size:10px; color:var(--ink-soft); font-weight:700; margin-bottom:2px; }
.vs-plate-value{ font-weight:800; font-size:16px; transition:all .3s; }
.vs-spark{ opacity:.85; }

.vs-bed-footer{ display:flex; align-items:center; justify-content:space-between; font-size:10.5px; color:var(--ink-soft); border-top:1px dashed var(--line); padding-top:8px; }
.vs-3d-hint{ position:absolute; top:10px; right:-2px; transform:translateX(calc(100% - 2px)); opacity:0; pointer-events:none; }
.vs-bed-card:hover .vs-3d-hint{ opacity:0; }

.vs-log-panel{ background:var(--surface); border:1px solid var(--line); border-radius:16px; padding:14px 16px; }
.vs-log-head{ display:flex; align-items:center; gap:8px; font-weight:700; font-size:14px; margin-bottom:10px; }
.vs-log-list{ max-height:260px; overflow-y:auto; display:flex; flex-direction:column-reverse; gap:0; }
.vs-log-list-static{ flex-direction:column; max-height:340px; }
.vs-log-item{ display:flex; align-items:center; gap:10px; padding:7px 0; border-bottom:1px solid var(--line); font-size:12.5px; }
.vs-log-item:last-child{ border-bottom:none; }
.vs-log-time{ color:var(--ink-soft); font-size:11px; white-space:nowrap; font-weight:600; }
.vs-log-bed{ background:var(--bg); padding:2px 7px; border-radius:6px; font-weight:700; font-size:10.5px; white-space:nowrap; }
.vs-log-text{ color:var(--ink); }

.vs-toast-stack{ position:fixed; top:74px; right:20px; display:flex; flex-direction:column; gap:8px; z-index:60; }
.vs-toast{ display:flex; align-items:center; gap:8px; background:var(--surface); border:1px solid var(--line); box-shadow:0 10px 24px rgba(16,37,59,0.16);
  padding:10px 14px; border-radius:10px; font-size:12.5px; font-weight:600; animation:vsToastIn .25s ease; min-width:220px; }
.vs-toast-ok{ border-left:3px solid var(--ok); color:var(--ok); }
.vs-toast-danger{ border-left:3px solid var(--crit); color:var(--crit); }
.vs-toast-warn{ border-left:3px solid var(--warn); color:var(--warn-toast, #B8860B); }

.vs-modal-backdrop{ position:fixed; inset:0; background:rgba(10,20,32,0.55); backdrop-filter:blur(2px); display:flex;
  align-items:center; justify-content:center; z-index:100; animation:vsFadeSlide .2s ease; padding:16px; }
.vs-modal{ width:min(560px,92vw); max-height:88vh; overflow-y:auto; background:var(--surface); border-radius:20px; padding:22px 24px 20px;
  box-shadow:0 0 0 3px var(--ring), 0 30px 60px rgba(0,0,0,0.35); animation:vsModalIn .3s cubic-bezier(.2,.8,.3,1); }
.vs-modal-head{ display:flex; align-items:flex-start; gap:12px; margin-bottom:16px; }
.vs-modal-icon-wrap{ width:46px; height:46px; border-radius:12px; background:rgba(226,59,59,0.1); color:var(--crit); display:flex; align-items:center; justify-content:center; flex-shrink:0; }
.vs-modal-warn-icon{ animation:vsWarnIcon 1.6s ease-in-out infinite; }
.vs-modal-title{ font-weight:800; font-size:17px; }
.vs-modal-sub{ font-size:11.5px; color:var(--ink-soft); }
.vs-modal-close{ margin-left:auto; background:none; border:none; color:var(--ink-soft); cursor:pointer; }
.vs-modal-grid{ display:grid; grid-template-columns:1fr 1fr; gap:10px 16px; margin-bottom:14px; }
.vs-field{ display:flex; flex-direction:column; gap:1px; }
.vs-field-label{ font-size:10.5px; color:var(--ink-soft); font-weight:700; text-transform:uppercase; letter-spacing:.4px; }
.vs-field-value{ font-size:13.5px; font-weight:700; }
.vs-modal-plates{ display:grid; grid-template-columns:repeat(4,1fr); gap:8px; margin-bottom:14px; }
.vs-modal-plate{ background:var(--bg); border-radius:9px; padding:7px; display:flex; flex-direction:column; align-items:center; gap:2px; font-size:10px; color:var(--ink-soft); font-weight:700; }
.vs-modal-plate-value{ font-size:15px; color:var(--ink); }
.vs-modal-actions-title{ font-weight:700; font-size:12.5px; margin-bottom:6px; }
.vs-modal-actions{ margin:0 0 16px; padding-left:18px; font-size:12.5px; color:var(--ink-soft); display:flex; flex-direction:column; gap:3px; }
.vs-modal-buttons{ display:flex; gap:8px; justify-content:flex-end; flex-wrap:wrap; }
.vs-btn{ display:flex; align-items:center; gap:6px; font-weight:700; font-size:12.5px; padding:9px 16px; border-radius:10px; cursor:pointer; border:1px solid transparent; transition:transform .15s, box-shadow .15s; }
.vs-btn:hover{ transform:translateY(-1px); }
.vs-btn-primary{ background:var(--medblue); color:#fff; box-shadow:0 6px 16px rgba(29,111,165,0.35); }
.vs-btn-outline{ background:var(--surface); border-color:var(--line); color:var(--ink); }
.vs-btn-ghost{ background:transparent; color:var(--ink-soft); }

.vs-modal-3d{ width:min(920px,94vw); }
.vs-3d-layout{ display:flex; gap:16px; flex-wrap:wrap; }
.vs-3d-canvas{ flex:2 1 460px; height:420px; border-radius:14px; overflow:hidden; background:#eaf4fb; border:1px solid var(--line); touch-action:none; cursor:grab; }
.vs-3d-canvas:active{ cursor:grabbing; }
.vs-3d-side{ flex:1 1 220px; display:flex; flex-direction:column; gap:9px; }
.vs-3d-risk{ align-self:flex-start; margin-bottom:4px; }
.vs-3d-plate-list{ margin-top:8px; border-top:1px dashed var(--line); padding-top:8px; display:flex; flex-direction:column; gap:6px; }
.vs-3d-plate-row{ display:flex; justify-content:space-between; font-size:12.5px; }

/* views / panels */
.vs-panel{ background:var(--surface); border:1px solid var(--line); border-radius:16px; padding:18px 20px; }
.vs-panel-head{ display:flex; align-items:center; justify-content:space-between; margin-bottom:14px; flex-wrap:wrap; gap:10px; }
.vs-panel-head h2{ margin:0; font-size:18px; font-weight:800; }
.vs-subhead{ font-size:13px; font-weight:700; color:var(--ink-soft); text-transform:uppercase; letter-spacing:.4px; margin:16px 0 8px; }
.vs-search{ display:flex; align-items:center; gap:7px; background:var(--bg); border:1px solid var(--line); border-radius:10px; padding:7px 11px; }
.vs-search input{ border:none; background:transparent; outline:none; font-size:13px; color:var(--ink); width:220px; }
.vs-table-wrap{ overflow-x:auto; }
.vs-table{ width:100%; border-collapse:collapse; font-size:12.5px; }
.vs-table th{ text-align:left; padding:9px 10px; color:var(--ink-soft); font-weight:700; font-size:11px; text-transform:uppercase; border-bottom:2px solid var(--line); white-space:nowrap; }
.vs-table td{ padding:9px 10px; border-bottom:1px solid var(--line); white-space:nowrap; }
.vs-mono{ font-weight:700; }
.vs-td-sub{ font-size:10.5px; color:var(--ink-soft); font-weight:500; }
.vs-row-risk-high td:first-child, .vs-row-risk-critical td:first-child{ border-left:3px solid var(--crit); }
.vs-mini-btn{ width:26px; height:26px; border-radius:7px; border:1px solid var(--line); background:var(--bg); color:var(--medblue); cursor:pointer; display:flex; align-items:center; justify-content:center; }
.vs-empty{ text-align:center; color:var(--ink-soft); padding:20px; }
.vs-empty-card{ background:var(--bg); border-radius:12px; padding:16px; color:var(--ink-soft); font-size:13px; }

.vs-alert-list{ display:flex; flex-direction:column; gap:10px; margin-bottom:6px; }
.vs-alert-card{ display:flex; align-items:center; gap:12px; padding:12px 14px; border:1.5px solid; border-radius:12px; background:var(--bg); }
.vs-alert-info{ display:flex; flex-direction:column; gap:2px; font-size:12.5px; flex:1; }

.vs-history-layout{ display:flex; gap:16px; flex-wrap:wrap; }
.vs-patient-picker{ flex:1 1 200px; max-width:230px; display:flex; flex-direction:column; gap:4px; }
.vs-picker-item{ display:flex; align-items:center; gap:8px; padding:8px 10px; border-radius:9px; border:1px solid var(--line); background:var(--bg); color:var(--ink); font-size:12.5px; font-weight:600; cursor:pointer; text-align:left; }
.vs-picker-item.active{ border-color:var(--medblue); color:var(--medblue); background:rgba(29,111,165,0.07); }
.vs-history-content{ flex:3 1 420px; }
.vs-history-title{ font-weight:700; font-size:14px; margin-bottom:2px; }
.vs-history-note{ font-size:11px; color:var(--ink-soft); }
.vs-chart-box{ margin-top:10px; background:var(--bg); border-radius:12px; padding:10px; }
.vs-chart-box h4{ margin:2px 0 6px; font-size:12.5px; }
.vs-history-facts{ display:flex; gap:20px; margin-top:12px; flex-wrap:wrap; }

.vs-help-text{ font-size:12.5px; color:var(--ink-soft); margin:0 0 12px; }
.vs-report-actions{ display:flex; gap:8px; margin-bottom:16px; flex-wrap:wrap; }
.vs-report-grid{ display:grid; grid-template-columns:repeat(auto-fit,minmax(100px,1fr)); gap:10px; margin-bottom:16px; }
.vs-report-tile{ background:var(--bg); border-radius:10px; padding:10px; display:flex; flex-direction:column; align-items:center; }
.vs-report-tile-value{ font-weight:800; font-size:18px; }
.vs-report-tile-label{ font-size:10.5px; color:var(--ink-soft); font-weight:600; }

.vs-analytics-grid{ display:grid; grid-template-columns:repeat(auto-fit,minmax(320px,1fr)); gap:16px; }

.vs-settings-grid{ display:grid; grid-template-columns:repeat(auto-fit,minmax(220px,1fr)); gap:14px; margin-bottom:16px; }
.vs-settings-card{ background:var(--bg); border-radius:12px; padding:14px; display:flex; flex-direction:column; gap:6px; }
.vs-settings-card h4{ margin:0 0 4px; font-size:13px; }
.vs-input{ border:1px solid var(--line); border-radius:8px; padding:7px 10px; font-size:13px; background:var(--surface); color:var(--ink); margin-bottom:6px; }
.vs-toggle-row{ display:flex; align-items:center; gap:8px; font-size:12.5px; font-weight:600; }
`;

/* ---------------- Mount ---------------- */
import { createRoot } from "react-dom/client";
createRoot(document.getElementById("root")).render(<VitalS />);
