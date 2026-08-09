#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VitalS Application Controller
===============================================================================

This module is the single entry point and orchestration layer for the VitalS
Raspberry Pi kiosk application. It is intentionally "thin": it does not
implement business logic itself, it *coordinates* the existing manager
classes (ConfigManager, BackendManager, FrontendManager) and the
ui.splash.SplashScreen UI component through well-defined, narrow interfaces.

NOTE ON THE DASHBOARD WINDOW: the dashboard is intentionally NOT a separate
ui.dashboard module at this stage. The Gtk.Window + WebKit2.WebView pair is
constructed directly inside this controller (see `_build_dashboard_window`
below) to keep the number of moving parts minimal while the application is
still stabilizing. Once the app is stable, `_build_dashboard_window` can be
lifted verbatim into a `ui/dashboard.py` module and injected back in via
`dashboard_factory` -- nothing else in this file would need to change.

Responsibilities of VitalSApplication (and only these):
    1. Read config.json                    -> ConfigManager
    2. Show the splash screen               -> ui.splash.SplashScreen
    3. Start the backend (UDP server)       -> core.backend_manager.BackendManager
    4. Start the frontend (http.server)     -> core.frontend_manager.FrontendManager
    5. Poll http://127.0.0.1:8080 until it responds (non-blocking, no time.sleep)
    6. Open the dashboard in a WebKit2 WebView (built inline, see note above)
    7. Handle clean shutdown (SIGINT/SIGTERM, window close, fatal errors)
    8. Stop backend + frontend on exit
    9. Expose extension points for future modules (Admin Login, Settings,
       Kiosk Mode, Restart, Shutdown, Auto Boot) without requiring this
       controller to be rewritten.

Design principles applied
--------------------------------------------------------------------------
- Single Responsibility : VitalSApplication only orchestrates the lifecycle.
  All actual backend/frontend/process work stays inside the existing manager
  classes. All actual widget construction stays inside the ui.* modules.
- Open/Closed            : new lifecycle stages (login, settings, kiosk,
  restart, shutdown, auto-boot) are added by implementing the corresponding
  `on_*` hook / `_transition_to_*` method and wiring it into
  `_LIFECYCLE_TRANSITIONS`, without touching the startup sequence itself.
- Liskov / Interface     : the controller talks to managers/UI only through
  the minimal interface documented in `ASSUMED_INTERFACES` below. As long as
  the concrete classes honor that contract, they are swappable.
- Interface Segregation  : the controller never reaches into manager
  internals; it only calls start()/stop()/is_running().
- Dependency Inversion   : concrete manager/UI classes are injected via
  simple factory callables, so tests or future variants (e.g. a Docker
  backend manager) can be substituted without editing this file.

Assumed public interfaces of existing components
--------------------------------------------------------------------------
These classes already exist in the project and are NOT rewritten here. This
controller is written against the following minimal contract. If the actual
signatures differ, only the small `_instantiate_*` factory methods below
need to be adjusted -- the rest of the orchestration logic is unaffected.

    ConfigManager(config_path: str)
        .load() -> dict                      # parses config.json
        .get(key: str, default=None) -> Any   # optional convenience accessor

    BackendManager()                         # no constructor arguments
        .start() -> None                     # activates venv & starts udp_server.py
        .stop()  -> None                     # terminates the backend process
        .is_running() -> bool

    FrontendManager()                        # no constructor arguments
        .start() -> None                     # starts `python3 -m http.server 8080`
        .stop()  -> None
        .is_running() -> bool

    ui.splash.SplashScreen(Gtk.Window)
        .show_all() / .destroy()

The dashboard window itself is built directly with Gtk.Window + WebKit2.WebView
inside this file (`_build_dashboard_window`) rather than through a ui.dashboard
module -- see the note above.

Future (NOT implemented here, only wired as extension points):
    ui.login.AdminLoginWindow
    ui.settings.SettingsWindow
    Kiosk mode / Shutdown / Restart / Auto Boot system integration
===============================================================================
"""

import os
import sys
import signal
import logging
import threading
import urllib.request
import urllib.error
import json
import subprocess
from logging.handlers import RotatingFileHandler
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Optional, Callable, Dict, Any

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("WebKit2", "4.1")
from gi.repository import Gtk, GLib, WebKit2, Gdk  # noqa: E402  (must follow gi.require_version)

from core.config_manager import ConfigManager
from core.backend_manager import BackendManager
from core.frontend_manager import FrontendManager
from ui.splash import SplashScreen

# ---------------------------------------------------------------------------
# Future modules -- intentionally NOT imported/implemented yet.
# When they are built, uncomment the imports and fill in the corresponding
# `_transition_to_*` methods below. The lifecycle map at the bottom of this
# file documents exactly where each one plugs in.
# ---------------------------------------------------------------------------
# from ui.login import AdminLoginWindow
# from ui.settings import SettingsWindow


# ---------------------------------------------------------------------------
# Module-level constants
# ---------------------------------------------------------------------------
APP_ROOT: str = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH: str = os.path.join(APP_ROOT, "config.json")
LOG_DIR: str = os.path.join(APP_ROOT, "logs")
LOG_FILE: str = os.path.join(LOG_DIR, "app.log")

# Sensible defaults; anything present in config.json overrides these.
DEFAULT_CONFIG: Dict[str, Any] = {
    "frontend": {
        "url": "http://127.0.0.1:8080",
        "ready_poll_interval_ms": 500,
        "ready_poll_timeout_s": 30,
        "ready_request_timeout_s": 1.5,
    },
    # The dashboard (WebView) connects to this Flask-SocketIO backend over
    # Socket.IO once it's loaded. On a cold boot the backend (imports,
    # venv activation, hardware/serial init, etc.) can take noticeably
    # longer to come up than the plain `http.server` frontend, so the
    # dashboard must not be opened until BOTH are actually reachable --
    # otherwise the WebView loads before port 3000 is listening and the
    # very first Socket.IO handshake races the backend's own startup.
    "backend": {
        "host": "127.0.0.1",
        "port": 3000,
        "ready_poll_interval_ms": 500,
        "ready_poll_timeout_s": 45,
    },
    "logging": {
        "level": "INFO",
        "max_bytes": 5 * 1024 * 1024,
        "backup_count": 3,
    },
    # Controls how the dashboard window is presented. This is a top-level
    # config.json key (not nested) so a future Administrator panel can
    # toggle it independently and have app.py honor the change on next
    # restart without any code modification.
    "kiosk_mode": True,
}


def _deep_merge(base: Dict[str, Any], override: Dict[str, Any]) -> Dict[str, Any]:
    """
    Recursively merges `override` on top of `base` without mutating either
    input. Used to layer config.json values over DEFAULT_CONFIG so missing
    keys never cause a KeyError downstream.
    """
    merged = dict(base)
    for key, value in (override or {}).items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = _deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


def _setup_logging(level_name: str, max_bytes: int, backup_count: int) -> logging.Logger:
    """
    Configures a rotating file handler plus a console handler. Returns the
    root application logger. Safe to call exactly once at process start.
    """
    os.makedirs(LOG_DIR, exist_ok=True)

    logger = logging.getLogger("vitals")
    logger.setLevel(getattr(logging, level_name.upper(), logging.INFO))

    formatter = logging.Formatter(
        fmt="%(asctime)s [%(levelname)s] [%(threadName)s] %(name)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    file_handler = RotatingFileHandler(
        LOG_FILE, maxBytes=max_bytes, backupCount=backup_count, encoding="utf-8"
    )
    file_handler.setFormatter(formatter)

    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setFormatter(formatter)

    logger.addHandler(file_handler)
    logger.addHandler(console_handler)
    logger.propagate = False
    return logger



class _ShutdownRequestHandler(BaseHTTPRequestHandler):
    """Local-only control endpoint used by the dashboard Settings page."""

    application = None

    def _send_json(self, status_code: int, payload: Dict[str, Any]) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "http://127.0.0.1:8080")
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self) -> None:
        self._send_json(204, {})

    def do_POST(self) -> None:
        if self.path != "/api/shutdown":
            self._send_json(404, {"success": False, "error": "Not found"})
            return

        self._send_json(200, {"success": True, "message": "VitalS shutdown initiated"})
        application = type(self).application
        if application is not None:
            GLib.idle_add(application._shutdown_from_dashboard)

    def log_message(self, format, *args) -> None:
        return


class ApplicationState:
    """Enumerates the lifecycle states of the controller (informational/logging use)."""
    INITIALIZING = "INITIALIZING"
    LOADING_CONFIG = "LOADING_CONFIG"
    SPLASH_VISIBLE = "SPLASH_VISIBLE"
    STARTING_BACKEND = "STARTING_BACKEND"
    STARTING_FRONTEND = "STARTING_FRONTEND"
    WAITING_FOR_FRONTEND = "WAITING_FOR_FRONTEND"
    DASHBOARD_VISIBLE = "DASHBOARD_VISIBLE"
    # Future states (extension points, not yet reachable):
    ADMIN_LOGIN = "ADMIN_LOGIN"
    SETTINGS = "SETTINGS"
    KIOSK_MODE = "KIOSK_MODE"
    RESTARTING = "RESTARTING"
    SHUTTING_DOWN = "SHUTTING_DOWN"
    AUTO_BOOT = "AUTO_BOOT"


class VitalSApplication:
    """
    Central lifecycle controller for the VitalS application.

    This class owns no business logic. It sequences calls to the existing
    manager classes and UI windows, and guarantees that shutdown always
    stops what it started, exactly once, regardless of which path triggered
    the shutdown (window closed by user, fatal startup error, OS signal).
    """

    def __init__(
        self,
        config_manager_factory: Callable[[str], ConfigManager] = ConfigManager,
        backend_manager_factory: Callable[[], BackendManager] = BackendManager,
        frontend_manager_factory: Callable[[], FrontendManager] = FrontendManager,
        splash_factory: Callable[[], SplashScreen] = SplashScreen,
        dashboard_factory: Optional[Callable[[str], Gtk.Window]] = None,
    ) -> None:
        # Factories are injected (Dependency Inversion) so alternate
        # implementations can be substituted without editing this class.
        #
        # dashboard_factory defaults to the controller's own inline builder
        # (`_build_dashboard_window`) rather than an external ui.dashboard
        # class, per current architecture decision -- see the module
        # docstring. A caller may still inject a different factory (e.g.
        # once ui/dashboard.py exists) without touching the rest of the
        # class.
        self._config_manager_factory = config_manager_factory
        self._backend_manager_factory = backend_manager_factory
        self._frontend_manager_factory = frontend_manager_factory
        self._splash_factory = splash_factory
        self._dashboard_factory = dashboard_factory or self._build_dashboard_window

        self.logger: logging.Logger = logging.getLogger("vitals.app")
        self.state: str = ApplicationState.INITIALIZING

        self.config: Dict[str, Any] = {}
        self.backend_manager: Optional[BackendManager] = None
        self.frontend_manager: Optional[FrontendManager] = None
        self.splash: Optional[SplashScreen] = None
        self.dashboard: Optional[Gtk.Window] = None
        self._dashboard_webview: Optional[WebKit2.WebView] = None

        # Thread-safety: startup work runs on a background thread so the
        # splash screen stays responsive; shutdown may be triggered from the
        # GTK main thread (window close, signal) or from the background
        # thread (fatal startup error). This lock guarantees shutdown logic
        # runs exactly once no matter which thread calls it.
        self._shutdown_lock = threading.Lock()
        self._is_shutting_down = False

        self._poll_source_id: Optional[int] = None
        self._poll_deadline_monotonic: Optional[float] = None
        self._backend_poll_source_id: Optional[int] = None
        self._backend_poll_deadline_monotonic: Optional[float] = None
        self._shutdown_server: Optional[ThreadingHTTPServer] = None
        self._shutdown_server_thread: Optional[threading.Thread] = None
        self._shutdown_control_port = 3010

    # ------------------------------------------------------------------
    # Public entry point
    # ------------------------------------------------------------------
    def run(self) -> int:
        """
        Boots the application. Blocks on the GTK main loop until shutdown.
        Returns a process exit code.
        """
        self._exit_code = 0
        try:
            self._install_signal_handlers()
            self._start_shutdown_control_server()
            # Splash is shown first so the operator sees feedback
            # immediately; configuration loading happens right after, while
            # the splash is already visible and the GTK main loop is about
            # to start pumping events.
            self._show_splash()
            self._load_configuration()
            # Backend/frontend startup can involve process spawning and
            # venv activation, which must never block the GTK main loop
            # (and therefore never block splash-screen rendering).
            threading.Thread(
                target=self._startup_sequence,
                name="VitalS-Startup",
                daemon=True,
            ).start()
            Gtk.main()
        except Exception:
            self.logger.exception("Unhandled exception while running VitalS.")
            self._exit_code = 1
        return self._exit_code

    def _shutdown_from_dashboard(self) -> bool:
        """Power off the entire Raspberry Pi from the dashboard."""
        self.logger.warning("Raspberry Pi shutdown requested from dashboard Settings.")

        def power_off():
            try:
                self.logger.info("Executing Raspberry Pi power-off command.")
                subprocess.Popen(
                    ["sudo", "-n", "/sbin/shutdown", "-h", "now"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )
            except Exception:
                self.logger.exception("Failed to start Raspberry Pi power-off command.")
            return False

        GLib.timeout_add(250, power_off)
        return False

    def _start_shutdown_control_server(self) -> None:
        """Start the localhost API used by the Settings shutdown button."""
        try:
            _ShutdownRequestHandler.application = self
            self._shutdown_server = ThreadingHTTPServer(
                ("127.0.0.1", self._shutdown_control_port),
                _ShutdownRequestHandler,
            )
            self._shutdown_server_thread = threading.Thread(
                target=self._shutdown_server.serve_forever,
                name="VitalS-ShutdownAPI",
                daemon=True,
            )
            self._shutdown_server_thread.start()
            self.logger.info(
                "Shutdown control API listening on 127.0.0.1:%s",
                self._shutdown_control_port,
            )
        except Exception:
            self._shutdown_server = None
            self._shutdown_server_thread = None
            _ShutdownRequestHandler.application = None
            self.logger.exception("Could not start shutdown control API.")

    def _stop_shutdown_control_server(self) -> None:
        """Stop the localhost shutdown API during normal application teardown."""
        server = self._shutdown_server
        self._shutdown_server = None
        self._shutdown_server_thread = None

        if server is not None:
            try:
                server.shutdown()
            except Exception:
                pass
            try:
                server.server_close()
            except Exception:
                pass

        _ShutdownRequestHandler.application = None

    def _shutdown_from_dashboard(self) -> bool:
        """Power off the entire Raspberry Pi from the dashboard."""
        self.logger.warning(
            "Raspberry Pi shutdown requested from dashboard Settings."
        )

        def power_off() -> bool:
            try:
                self.logger.info("Executing Raspberry Pi power-off command.")
                subprocess.Popen(
                    ["sudo", "-n", "/sbin/shutdown", "-h", "now"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )
            except Exception:
                self.logger.exception(
                    "Failed to start Raspberry Pi power-off command."
                )
            return False

        # Give the HTTP response time to complete before power-off.
        GLib.timeout_add(250, power_off)
        return False

    # ------------------------------------------------------------------
    # Step 1: configuration
    # ------------------------------------------------------------------
    def _load_configuration(self) -> None:
        self.state = ApplicationState.LOADING_CONFIG
        self.logger.info("Loading configuration from %s", CONFIG_PATH)
        config_manager = self._config_manager_factory(CONFIG_PATH)
        try:
            raw_config = config_manager.load()
        except AttributeError:
            # Fallback for a ConfigManager variant that exposes .get() only.
            raw_config = getattr(config_manager, "config", {}) or {}
        except Exception:
            self.logger.exception(
                "[ConfigManager] Failed to load config.json; falling back to built-in defaults."
            )
            raw_config = {}

        if not raw_config:
            # ConfigManager.load() returned nothing usable (None or an
            # empty dict). This is surfaced loudly rather than silently
            # falling back to defaults, since it usually means
            # ConfigManager.load() isn't returning its parsed config.
            self.logger.warning(
                "[ConfigManager] config.json produced no configuration data "
                "(ConfigManager.load() returned nothing). Falling back to "
                "built-in defaults: %s", DEFAULT_CONFIG,
            )

        self.config = _deep_merge(DEFAULT_CONFIG, raw_config or {})
        self.logger.info("Loaded configuration: %s", self.config)
        self.logger.info("Kiosk Mode: %s", self.config.get("kiosk_mode"))

    # ------------------------------------------------------------------
    # Step 2: splash screen
    # ------------------------------------------------------------------
    def _show_splash(self) -> None:
        self.state = ApplicationState.SPLASH_VISIBLE
        self.logger.info("Showing splash screen.")
        self.splash = self._splash_factory()
        self.splash.show_all()

    def _close_splash(self) -> None:
        if self.splash is not None:
            try:
                self.splash.destroy()
            except Exception:
                self.logger.exception("Error while closing splash screen.")
            finally:
                self.splash = None

    # ------------------------------------------------------------------
    # Steps 3-5: backend, frontend, readiness poll
    # This entire method runs on the background "VitalS-Startup" thread.
    # Any UI mutation from here MUST be marshalled back onto the GTK main
    # thread via GLib.idle_add.
    # ------------------------------------------------------------------
    def _startup_sequence(self) -> None:
        try:
            self._start_backend()
            self._start_frontend()
        except Exception as exc:
            self.logger.exception("Startup sequence failed.")
            GLib.idle_add(self._handle_fatal_startup_error, str(exc))
            return

        # Hand off to the GTK main loop for non-blocking readiness polling.
        GLib.idle_add(self._begin_frontend_readiness_poll)

    def _start_backend(self) -> None:
        self.state = ApplicationState.STARTING_BACKEND
        self.logger.info("Starting backend service.")
        # BackendManager takes no constructor arguments; configuration (if
        # the manager needs any) is expected to be handled internally by
        # BackendManager itself, not injected here.
        self.backend_manager = self._backend_manager_factory()
        self.backend_manager.start()
        self.logger.info("Backend Started successfully.")

    def _start_frontend(self) -> None:
        self.state = ApplicationState.STARTING_FRONTEND
        self.logger.info("Starting frontend service.")
        # FrontendManager takes no constructor arguments; same rationale
        # as BackendManager above.
        self.frontend_manager = self._frontend_manager_factory()
        self.frontend_manager.start()
        self.logger.info("Frontend Started successfully.")

    def _begin_frontend_readiness_poll(self) -> bool:
        """
        Schedules a repeating GLib timeout that checks whether the frontend
        HTTP endpoint is responding. This deliberately avoids time.sleep():
        the GTK main loop remains fully responsive (splash screen keeps
        rendering/animating) while polling happens in the background via
        timer callbacks.
        """
        self.state = ApplicationState.WAITING_FOR_FRONTEND
        frontend_cfg = self.config["frontend"]
        interval_ms = int(frontend_cfg["ready_poll_interval_ms"])
        timeout_s = float(frontend_cfg["ready_poll_timeout_s"])

        self._poll_deadline_monotonic = GLib.get_monotonic_time() / 1_000_000.0 + timeout_s
        self.logger.info(
            "Polling %s for readiness (interval=%dms, timeout=%.1fs).",
            frontend_cfg["url"], interval_ms, timeout_s,
        )
        self._poll_source_id = GLib.timeout_add(interval_ms, self._poll_frontend_ready)
        return False  # one-shot idle callback; do not repeat this dispatcher itself

    def _poll_frontend_ready(self) -> bool:
        """
        GLib timeout callback (runs on the GTK main thread). Returning True
        reschedules it for another interval; returning False stops polling.
        """
        if self._is_shutting_down:
            return False

        if self._is_frontend_responding():
            self.logger.info("Frontend Ready - responding at %s", self.config["frontend"]["url"])
            self._poll_source_id = None
            self._on_frontend_ready()
            return False

        now = GLib.get_monotonic_time() / 1_000_000.0
        if self._poll_deadline_monotonic is not None and now >= self._poll_deadline_monotonic:
            self._poll_source_id = None
            self._handle_fatal_startup_error(
                "Frontend did not become ready within the configured timeout."
            )
            return False

        return True  # keep polling

    def _is_frontend_responding(self) -> bool:
        """
        Performs a single, short-timeout HTTP GET against the frontend URL.
        Never raises; any failure (connection refused, timeout, HTTP error
        code) is treated simply as "not ready yet".
        """
        url = self.config["frontend"]["url"]
        request_timeout = float(self.config["frontend"]["ready_request_timeout_s"])
        try:
            with urllib.request.urlopen(url, timeout=request_timeout) as response:
                return 200 <= response.status < 400
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError):
            return False

    # ------------------------------------------------------------------
    # Step 5b: backend (Socket.IO) readiness poll
    #
    # The dashboard's JS connects to the backend independently and does
    # have its own retry loop, but that loop only starts running *after*
    # the WebView has loaded -- it can't paper over a backend that isn't
    # listening yet at boot. Gating dashboard-open on this poll (in
    # addition to the frontend poll) removes the race instead of relying
    # on client-side retries to eventually win it.
    # ------------------------------------------------------------------
    def _on_frontend_ready(self) -> None:
        self.logger.info("Frontend ready. Waiting for backend before opening dashboard.")
        self._begin_backend_readiness_poll()

    def _begin_backend_readiness_poll(self) -> None:
        backend_cfg = self.config["backend"]
        interval_ms = int(backend_cfg["ready_poll_interval_ms"])
        timeout_s = float(backend_cfg["ready_poll_timeout_s"])

        self._backend_poll_deadline_monotonic = (
            GLib.get_monotonic_time() / 1_000_000.0 + timeout_s
        )
        self.logger.info(
            "Polling backend at %s:%s for readiness (interval=%dms, timeout=%.1fs).",
            backend_cfg["host"], backend_cfg["port"], interval_ms, timeout_s,
        )
        self._backend_poll_source_id = GLib.timeout_add(interval_ms, self._poll_backend_ready)

    def _poll_backend_ready(self) -> bool:
        if self._is_shutting_down:
            return False

        if self._is_backend_responding():
            self.logger.info("Backend Ready - listening on %s:%s",
                              self.config["backend"]["host"], self.config["backend"]["port"])
            self._backend_poll_source_id = None
            self._on_backend_ready()
            return False

        now = GLib.get_monotonic_time() / 1_000_000.0
        if self._backend_poll_deadline_monotonic is not None and now >= self._backend_poll_deadline_monotonic:
            self._backend_poll_source_id = None
            # Do not hard-fail the whole app over this -- the dashboard's
            # own Socket.IO client will keep retrying every few seconds on
            # its own. Opening late is far better than never opening.
            self.logger.warning(
                "Backend did not become reachable within %.1fs. Opening "
                "dashboard anyway; it will keep retrying the Socket.IO "
                "connection in the background.",
                float(self.config["backend"]["ready_poll_timeout_s"]),
            )
            self._on_backend_ready()
            return False

        return True  # keep polling

    def _is_backend_responding(self) -> bool:
        """
        Checks for a live TCP listener on the backend host/port. A plain
        TCP connect (rather than an HTTP GET) is used deliberately: a
        Flask-SocketIO app may not have a route registered on "/", which
        would otherwise make a healthy backend look "not ready" just
        because it 404s.
        """
        import socket as _socket

        host = self.config["backend"]["host"]
        port = int(self.config["backend"]["port"])
        try:
            with _socket.create_connection((host, port), timeout=1.5):
                return True
        except OSError:
            return False

    # ------------------------------------------------------------------
    # Step 6: open dashboard
    # ------------------------------------------------------------------
    def _on_backend_ready(self) -> None:
        # Per the required startup sequence, the dashboard is opened first
        # and the splash is only closed once the dashboard window is up,
        # so there is never a gap where neither is visible.
        self._open_dashboard()
        self._close_splash()

    def _open_dashboard(self) -> None:
        self.state = ApplicationState.DASHBOARD_VISIBLE
        url = self.config["frontend"]["url"]
        self.logger.info("Opening dashboard WebView at %s", url)

        self.dashboard = self._dashboard_factory(url)
        # The user closing the dashboard window is the normal exit path for
        # a kiosk application; wire it straight into the shutdown sequence.
        self.dashboard.connect("destroy", self._on_dashboard_closed)

        self.dashboard.show_all()
        # Apply the correct fullscreen/windowed geometry shortly AFTER the
        # window is actually mapped to the screen, using the exact same
        # logic that already works reliably when triggered live from the
        # Settings page. Doing this at window-creation time (inside the
        # "realize" signal) was unreliable on this window manager --
        # "realize" fires before the window is really drawn/mapped, so
        # move()/resize()/fullscreen() calls made there were silently
        # ignored even though the code logged success.
        GLib.timeout_add(300, self._apply_initial_kiosk_mode)
        self._start_kiosk_mode_watcher()

    def _on_dashboard_closed(self, *_args) -> None:
        self.logger.info("Dashboard window closed by user or system.")
        self._shutdown(exit_code=0)

    def _build_dashboard_window(self, url: str) -> Gtk.Window:
        """
        Constructs the dashboard window: a plain Gtk.Window hosting a
        WebKit2.WebView pointed at the frontend URL.

        Presentation mode is driven entirely by the top-level "kiosk_mode"
        config.json flag:
            - kiosk_mode = true  -> undecorated, non-resizable, fullscreen.
            - kiosk_mode = false -> decorated, resizable, normal-sized window.
        This flag is read fresh from `self.config` every time the window is
        built, so a future Administrator panel can flip it in config.json
        and have it take effect the next time the dashboard is (re)opened,
        with no changes to app.py required.

        This is deliberately inline in the controller for now rather than a
        separate ui/dashboard.py module (current architecture decision).
        The method is self-contained so it can be lifted into its own
        module later without touching any other part of this file -- the
        rest of the controller only depends on the returned object exposing
        `.connect("destroy", ...)` and `.show_all()`, which is exactly what
        a future ui.dashboard.DashboardWindow would need to provide as well.
        """
        kiosk_mode = bool(self.config.get("kiosk_mode", True))

        window = Gtk.Window(title="VitalS Dashboard")
        if kiosk_mode:
            window.set_resizable(True)
            window.set_decorated(False)
            self.logger.info(
                "Dashboard window will be created in kiosk mode (fullscreen, fixed)."
            )
        else:
            window.set_resizable(True)
            window.set_decorated(True)
            self.logger.info(
                "Dashboard window will be created in development mode (maximized, resizable)."
            )

        # Presentation is applied shortly after the window is mapped by
        # _open_dashboard(). Do not apply fullscreen/geometry in realize.
        # The window's own "destroy" signal (connected by the caller) is
        # what drives application shutdown, so no extra wiring is needed
        # here beyond constructing the widgets.

        webview = WebKit2.WebView()

        # Production-safe WebView settings: no developer tools, no
        # accidental context menu, sane defaults for a kiosk-style display.
        # set_enable_page_cache(False) added so the dashboard always loads
        # the current app.jsx / index.html from the frontend server instead
        # of a stale cached copy from a previous run (this was previously
        # causing the WebView to keep using an old hardcoded IP address
        # long after the source file on disk had been corrected).
        webkit_settings = webview.get_settings()
        webkit_settings.set_enable_developer_extras(False)
        webkit_settings.set_enable_write_console_messages_to_stdout(True)
        webkit_settings.set_enable_page_cache(False)
        webview.set_settings(webkit_settings)
        webview.connect("context-menu", lambda *_: True)  # suppress right-click menu
        webview.connect("load-changed", self._on_dashboard_load_changed)
        webview.connect("load-failed", self._on_dashboard_load_failed)

        webview.load_uri(url)
        webview.set_hexpand(True)
        webview.set_vexpand(True)
        window.add(webview)

        # Kept for diagnostics / potential future use (e.g. reload on
        # network recovery); not required by the base controller logic.
        self._dashboard_webview = webview

        return window

    def _on_dashboard_window_realize(self, window: Gtk.Window) -> None:
        """
        Diagnostic callback retained for compatibility.

        Do NOT change fullscreen/window geometry here. On Raspberry Pi/X11,
        the GTK ``realize`` signal can fire before the window is mapped, so
        geometry/fullscreen operations here may be ignored. The actual
        presentation is applied by ``_apply_initial_kiosk_mode`` after a
        short GLib timeout, once the window is mapped.
        """
        self.logger.info(
            "Dashboard window realized; waiting for mapped window before applying presentation mode."
        )

    def _apply_initial_kiosk_mode(self) -> bool:
        kiosk_mode = bool(self.config.get("kiosk_mode", True))
        self._apply_kiosk_mode(kiosk_mode)
        return False  # one-shot

    def _start_kiosk_mode_watcher(self) -> None:
        # Polls config.json every 2s for a kiosk_mode change made via the
        # admin panel (Settings page -> backend API -> config.json), and
        # applies it live to the already-open dashboard window, with no
        # app restart required.
        GLib.timeout_add(2000, self._check_kiosk_mode_change)

    def _check_kiosk_mode_change(self) -> bool:
        if self._is_shutting_down:
            return False
        try:
            with open(CONFIG_PATH, "r") as f:
                raw = json.load(f)
        except Exception:
            return True  # config mid-write or transient error; keep watching

        new_kiosk_mode = bool(raw.get("kiosk_mode", True))
        current_kiosk_mode = bool(self.config.get("kiosk_mode", True))

        if new_kiosk_mode != current_kiosk_mode:
            self.logger.info(
                "Kiosk mode changed via admin panel: %s -> %s",
                current_kiosk_mode, new_kiosk_mode,
            )
            self.config["kiosk_mode"] = new_kiosk_mode
            self._apply_kiosk_mode(new_kiosk_mode)

        return True  # keep watching

    def _x11_window_manager_kiosk(self, enable: bool) -> None:
        """Force the VitalS X11 window to the requested presentation state.

        On Raspberry Pi X11 desktops, GTK fullscreen can be acknowledged by
        the toolkit while the window manager still leaves the window at its
        previous small geometry.  wmctrl is therefore used as the final
        authority: identify the actual VitalS window, set its geometry to the
        monitor, then apply EWMH fullscreen/above and activate it.
        """
        if os.environ.get("DISPLAY") is None:
            return

        wmctrl = None
        for candidate in ("wmctrl", "/usr/bin/wmctrl", "/usr/local/bin/wmctrl"):
            try:
                result = subprocess.run(
                    [candidate, "-m"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=2,
                )
                if result.returncode == 0:
                    wmctrl = candidate
                    break
            except (FileNotFoundError, OSError, subprocess.SubprocessError):
                continue

        if not wmctrl:
            self.logger.warning("wmctrl is not available; using GTK presentation only.")
            return

        try:
            # Locate the real X11 window by title and obtain its window id.
            listing = subprocess.run(
                [wmctrl, "-lG"],
                capture_output=True,
                text=True,
                timeout=2,
            )

            dashboard_id = None
            for line in listing.stdout.splitlines():
                parts = line.split(None, 7)
                if len(parts) >= 8 and parts[7].strip() == "VitalS Dashboard":
                    dashboard_id = parts[0]
                    break

            if dashboard_id is None:
                # Fallback: title may have a transient suffix.
                for line in listing.stdout.splitlines():
                    parts = line.split(None, 7)
                    if len(parts) >= 8 and "VitalS Dashboard" in parts[7]:
                        dashboard_id = parts[0]
                        break

            if dashboard_id is None:
                self.logger.warning("wmctrl could not find the VitalS Dashboard X11 window.")
                return

            if enable:
                # Determine the actual monitor size from GTK/GDK.
                window = self.dashboard
                screen = window.get_screen()
                display = screen.get_display()
                gdk_window = window.get_window()
                monitor = display.get_monitor_at_window(gdk_window) if gdk_window else display.get_monitor(0)
                if monitor is None:
                    monitor = display.get_monitor(0)
                geometry = monitor.get_geometry()

                # 1) Explicitly set X11 geometry.  This fixes the Raspberry
                # Pi case where fullscreen leaves the window at 1024x700.
                subprocess.run(
                    [wmctrl, "-i", "-r", dashboard_id, "-e",
                     f"0,{geometry.x},{geometry.y},{geometry.width},{geometry.height}"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2,
                )

                # 2) Remove any stale normal/maximized state, then request
                # actual EWMH fullscreen and always-on-top.
                subprocess.run(
                    [wmctrl, "-i", "-r", dashboard_id, "-b",
                     "remove,maximized_vert,maximized_horz,hidden"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2,
                )
                subprocess.run(
                    [wmctrl, "-i", "-r", dashboard_id, "-b",
                     "add,fullscreen,above"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2,
                )
                subprocess.run(
                    [wmctrl, "-i", "-a", dashboard_id],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2,
                )

                self.logger.info(
                    "X11 kiosk enforced: window=%s geometry=%sx%s+%s+%s",
                    dashboard_id, geometry.width, geometry.height, geometry.x, geometry.y,
                )

            else:
                # Remove X11 kiosk state before GTK restores decorations and
                # the normal 1024x700 window.
                subprocess.run(
                    [wmctrl, "-i", "-r", dashboard_id, "-b",
                     "remove,fullscreen,above,sticky"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2,
                )
                subprocess.run(
                    [wmctrl, "-i", "-a", dashboard_id],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2,
                )

        except Exception:
            self.logger.exception("X11 window-manager kiosk enforcement failed.")

    def _apply_kiosk_mode(self, kiosk_mode: bool) -> None:
        """
        Apply kiosk or normal windowed presentation to the already-mapped
        dashboard window. This is the ONLY method that changes dashboard
        presentation state.
        """
        if self.dashboard is None:
            return

        window = self.dashboard

        try:
            screen = window.get_screen()
            display = screen.get_display()
            gdk_window = window.get_window()

            # Find the monitor containing the dashboard. If the window has not
            # received an X11 window yet, safely fall back to monitor 0.
            if gdk_window is not None:
                monitor = display.get_monitor_at_window(gdk_window)
            else:
                monitor = display.get_monitor(0)

            if monitor is None:
                self.logger.warning("Could not determine dashboard monitor; using monitor 0 geometry.")
                monitor = display.get_monitor(0)

            geometry = monitor.get_geometry()

            if kiosk_mode:
                # ---------------------------------------------------------
                # KIOSK MODE: true fullscreen
                # ---------------------------------------------------------
                window.set_keep_above(True)
                window.set_decorated(False)
                window.set_resizable(True)

                # Set the exact monitor geometry first.
                window.move(geometry.x, geometry.y)
                window.resize(geometry.width, geometry.height)

                # Show the window, then request real fullscreen.
                # Raspberry Pi/X11 can process the request asynchronously.
                window.present()
                window.fullscreen()
                window.present()

                # Final X11/EWMH enforcement. This handles Raspberry Pi
                # desktops where the launching terminal can remain above GTK.
                self._x11_window_manager_kiosk(True)

                self.logger.info(
                    "Applied kiosk mode: fullscreen (%sx%s) at (%s,%s)",
                    geometry.width,
                    geometry.height,
                    geometry.x,
                    geometry.y,
                )

                # Re-apply after the X11 window manager settles.
                GLib.timeout_add(300, self._force_kiosk_fullscreen)

            else:
                # ---------------------------------------------------------
                # NORMAL MODE: decorated, resizable desktop window
                # ---------------------------------------------------------
                window.set_keep_above(False)

                # Leave fullscreen before restoring normal decorations.
                window.unfullscreen()

                window.set_decorated(True)
                window.set_resizable(True)

                # Match the normal terminal-sized desktop window shown on
                # this Raspberry Pi. Change these two values later if you
                # want a different normal dashboard size.
                window_width = 1024
                window_height = 700

                window.resize(window_width, window_height)

                # Center the normal dashboard window on the active monitor.
                center_x = geometry.x + (geometry.width - window_width) // 2
                center_y = geometry.y + (geometry.height - window_height) // 2
                window.move(center_x, center_y)

                # Bring it to the foreground and remove X11 kiosk state.
                window.present()
                self._x11_window_manager_kiosk(False)

                self.logger.info(
                    "Applied normal window mode: %sx%s at (%s,%s)",
                    window_width,
                    window_height,
                    center_x,
                    center_y,
                )

        except Exception:
            self.logger.exception(
                "Failed to apply dashboard kiosk/windowed mode."
            )

    def _force_kiosk_fullscreen(self):
        """Re-apply kiosk fullscreen after the X11 window manager settles."""
        if self.dashboard is None or self._is_shutting_down:
            return False

        if not bool(self.config.get("kiosk_mode", True)):
            return False

        try:
            window = self.dashboard
            screen = window.get_screen()
            display = screen.get_display()
            gdk_window = window.get_window()

            if gdk_window is not None:
                monitor = display.get_monitor_at_window(gdk_window)
            else:
                monitor = display.get_monitor(0)

            if monitor is None:
                monitor = display.get_monitor(0)

            geometry = monitor.get_geometry()

            window.set_keep_above(True)
            window.set_decorated(False)
            window.set_resizable(True)
            window.move(geometry.x, geometry.y)
            window.resize(geometry.width, geometry.height)
            window.fullscreen()
            window.present()
            self._x11_window_manager_kiosk(True)

            self.logger.info(
                "Forced kiosk fullscreen: %sx%s at (%s,%s)",
                geometry.width,
                geometry.height,
                geometry.x,
                geometry.y,
            )
        except Exception:
            self.logger.exception("Failed to force kiosk fullscreen.")

        return False

    def _on_dashboard_load_changed(self, webview: "WebKit2.WebView", load_event) -> None:
        if load_event == WebKit2.LoadEvent.FINISHED:
            self.logger.info("Dashboard Loaded: %s", webview.get_uri())
        elif load_event == WebKit2.LoadEvent.STARTED:
            self.logger.debug("Dashboard WebView started loading %s", webview.get_uri())

    def _on_dashboard_load_failed(
        self, webview: "WebKit2.WebView", load_event, failing_uri: str, error
    ) -> bool:
        self.logger.error(
            "[Dashboard WebView] Failed to load %s (event=%s): %s",
            failing_uri, load_event, error,
        )
        # Returning False lets WebKit2 fall back to its own default error
        # handling (e.g. rendering its built-in error page) rather than
        # silently swallowing the failure.
        return False

    # ------------------------------------------------------------------
    # Error handling
    # ------------------------------------------------------------------
    def _handle_fatal_startup_error(self, message: str) -> bool:
        """
        Runs on the GTK main thread. Logs the failure, surfaces it to the
        operator, and performs a full shutdown so no orphaned backend or
        frontend processes are left behind.
        """
        self.logger.error("Fatal startup error: %s", message)
        self._close_splash()

        try:
            dialog = Gtk.MessageDialog(
                transient_for=None,
                flags=0,
                message_type=Gtk.MessageType.ERROR,
                buttons=Gtk.ButtonsType.OK,
                text="VitalS failed to start",
            )
            dialog.format_secondary_text(message)
            dialog.run()
            dialog.destroy()
        except Exception:
            self.logger.exception("Failed to display startup error dialog.")

        self._shutdown(exit_code=1)
        return False

    # ------------------------------------------------------------------
    # Steps 7-8: shutdown
    # ------------------------------------------------------------------
    def _install_signal_handlers(self) -> None:
        """
        Wires SIGINT/SIGTERM into the GTK main loop via GLib's unix signal
        integration so `systemctl stop`, Ctrl+C, or a supervisor process can
        trigger the exact same clean shutdown path as closing the window.
        """
        for sig in (signal.SIGINT, signal.SIGTERM):
            GLib.unix_signal_add(GLib.PRIORITY_HIGH, sig, self._on_os_signal, sig)

    def _on_os_signal(self, sig: int) -> bool:
        self.logger.info("Received OS signal %s. Initiating shutdown.", sig)
        self._shutdown(exit_code=0)
        return False  # do not keep this signal source alive

    def _shutdown(self, exit_code: int = 0) -> None:
        """
        Idempotent shutdown: safe to call multiple times / from multiple
        threads (window-close, signal handler, fatal error path). Only the
        first caller actually performs the teardown.
        """
        with self._shutdown_lock:
            if self._is_shutting_down:
                return
            self._is_shutting_down = True

        self.state = ApplicationState.SHUTTING_DOWN
        self.logger.info("Application Shutdown initiated (exit_code=%s).", exit_code)
        self._exit_code = exit_code

        if self._poll_source_id is not None:
            try:
                GLib.source_remove(self._poll_source_id)
            except Exception:
                pass
            self._poll_source_id = None

        if self._backend_poll_source_id is not None:
            try:
                GLib.source_remove(self._backend_poll_source_id)
            except Exception:
                pass
            self._backend_poll_source_id = None

        self._close_splash()
        self._stop_shutdown_control_server()

        if self.dashboard is not None:
            try:
                self.dashboard.destroy()
            except Exception:
                self.logger.exception("[Dashboard] Error while closing dashboard window.")
            finally:
                self.dashboard = None

        self._stop_service("frontend", self.frontend_manager)
        self._stop_service("backend", self.backend_manager)

        # Ensure Gtk.main() unblocks even if we are called from a
        # non-main thread (e.g. the background startup thread), i.e.
        # "Destroy GTK" and let the process exit cleanly with no orphaned
        # backend/frontend processes left running.
        GLib.idle_add(self._quit_main_loop)
        self.logger.info("Application Shutdown complete.")

    def _stop_service(self, name: str, manager) -> None:
        if manager is None:
            return
        try:
            self.logger.info("Stopping %s service.", name)
            manager.stop()
            self.logger.info("%s service stopped.", name.capitalize())
        except Exception:
            self.logger.exception("[%s] Error while stopping service.", name.capitalize())

    def _quit_main_loop(self) -> bool:
        if Gtk.main_level() > 0:
            Gtk.main_quit()
        return False

    # ------------------------------------------------------------------
    # Extension points for future modules.
    #
    # None of these are implemented yet (per requirements). They exist so
    # the eventual Admin Login / Settings / Kiosk Mode / Restart / Shutdown
    # / Auto Boot modules can be plugged into the controller by:
    #   (a) filling in the method body to construct/show the relevant
    #       window or perform the relevant system action, and
    #   (b) calling it from the appropriate trigger (e.g. a toolbar button
    #       in the dashboard, a hardware button GPIO callback, a scheduled
    #       systemd timer, etc.) -- none of which require changes to the
    #       startup sequence above.
    # ------------------------------------------------------------------
    def launch_admin_login(self) -> None:
        """Extension point: show ui.login.AdminLoginWindow. Not yet implemented."""
        self.logger.info("launch_admin_login() called but is not yet implemented.")
        # self.state = ApplicationState.ADMIN_LOGIN
        # login_window = AdminLoginWindow(on_success=self.open_settings)
        # login_window.show_all()

    def open_settings(self) -> None:
        """Extension point: show ui.settings.SettingsWindow. Not yet implemented."""
        self.logger.info("open_settings() called but is not yet implemented.")
        # self.state = ApplicationState.SETTINGS
        # settings_window = SettingsWindow(config=self.config)
        # settings_window.show_all()

    def enable_kiosk_mode(self) -> None:
        """Extension point: lock down window manager / disable exit chrome."""
        self.logger.info("enable_kiosk_mode() called but is not yet implemented.")
        # self.state = ApplicationState.KIOSK_MODE

    def restart_application(self) -> None:
        """Extension point: full clean shutdown followed by re-exec of app.py."""
        self.logger.info("restart_application() called but is not yet implemented.")
        # self.state = ApplicationState.RESTARTING
        # self._shutdown(exit_code=0)
        # os.execv(sys.executable, [sys.executable] + sys.argv)

    def shutdown_system(self) -> None:
        """Extension point: stop VitalS and power off the Raspberry Pi."""
        self.logger.info("shutdown_system() called but is not yet implemented.")
        # self._shutdown(exit_code=0)
        # subprocess.run(["sudo", "systemctl", "poweroff"], check=False)

    def configure_auto_boot(self) -> None:
        """Extension point: install/verify the systemd unit / autostart entry."""
        self.logger.info("configure_auto_boot() called but is not yet implemented.")


def main() -> int:
    """
    Process entry point. Configures logging using whatever settings are
    available (falling back to defaults if config.json cannot be read yet,
    since logging must be ready before configuration loading is attempted),
    then hands control to VitalSApplication.
    """
    log_settings = DEFAULT_CONFIG["logging"]
    logger = _setup_logging(
        level_name=log_settings["level"],
        max_bytes=log_settings["max_bytes"],
        backup_count=log_settings["backup_count"],
    )
    logger.info("=" * 70)
    logger.info("VitalS starting up.")

    application = VitalSApplication()
    exit_code = application.run()

    logger.info("VitalS exited with code %s.", exit_code)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
