"""
core/backend_manager.py
===============================================================================
Owns the backend (udp_server.py, Flask-SocketIO) child process.

Compared to the previous version, this adds exactly what app.py's readiness
poll needs in order to actually recover from a boot-time crash instead of
silently giving up:

    1. is_running()      -- app.py's docstring already assumed this existed;
                             it didn't. Now it does (checks the real process).
    2. stdout/stderr capture -- previously the child's output went nowhere
                             useful, so a startup crash (e.g. a USB/serial
                             sensor not enumerated yet right after boot) left
                             no trace anywhere. Now it's written to
                             logs/backend.log.
    3. Auto-restart with backoff -- if the process exits on its own (crash,
                             not a requested stop()), a background watchdog
                             thread restarts it a few times with a short
                             delay. This is the direct fix for "backend died
                             at boot before its hardware was ready, and never
                             came back".
===============================================================================
"""

import os
import subprocess
import threading
import time
import logging

logger = logging.getLogger("vitals.backend_manager")


class BackendManager:
    # How many times to auto-restart after an unexpected crash before
    # giving up and just leaving it stopped (so a permanently broken
    # backend doesn't restart-loop forever and spam the log/CPU).
    MAX_AUTO_RESTARTS = 5
    # Delay before each restart attempt. A few seconds gives slow-to-
    # enumerate USB/serial hardware time to show up before the next try.
    RESTART_DELAY_S = 3.0

    def __init__(self):
        self.process = None
        self._restart_count = 0
        self._stopping = False
        self._watchdog_thread = None
        self._log_file = None

        # core/backend_manager.py lives in VitalS-App/core/, so going up
        # one level gets us to VitalS-App/ regardless of where the whole
        # project folder is checked out or renamed in the future.
        self._app_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        self._backend_path = os.path.join(self._app_root, "backend")
        self._log_dir = os.path.join(self._app_root, "logs")

    # ------------------------------------------------------------------
    def start(self) -> None:
        self._stopping = False
        self._restart_count = 0
        self._spawn()

        # Watchdog runs for the lifetime of the manager; it notices if the
        # process exits on its own (as opposed to via stop()) and restarts
        # it, up to MAX_AUTO_RESTARTS times.
        self._watchdog_thread = threading.Thread(
            target=self._watchdog_loop, name="BackendManager-Watchdog", daemon=True
        )
        self._watchdog_thread.start()

    def _spawn(self) -> None:
        os.makedirs(self._log_dir, exist_ok=True)
        log_path = os.path.join(self._log_dir, "backend.log")

        # Open in append mode so restarts don't clobber earlier crash output
        # from the same boot -- that output is exactly what you need to see
        # to diagnose *why* it crashed the first time.
        self._log_file = open(log_path, "a", buffering=1)
        self._log_file.write(
            f"\n----- backend start attempt at {time.strftime('%Y-%m-%d %H:%M:%S')} "
            f"(restart #{self._restart_count}) -----\n"
        )

        command = (
            f"cd {self._backend_path} && "
            "source venv/bin/activate && "
            "python3 udp_server.py"
        )
        logger.info("Starting backend (attempt %d): %s", self._restart_count, command)
        self.process = subprocess.Popen(
            ["bash", "-c", command],
            stdout=self._log_file,
            stderr=self._log_file,
        )

    def _watchdog_loop(self) -> None:
        while not self._stopping:
            proc = self.process
            if proc is None:
                return

            exit_code = proc.wait()  # blocks until the process exits

            if self._stopping:
                # Exit was requested via stop(); nothing to do.
                return

            logger.error(
                "Backend process exited unexpectedly (exit code=%s).", exit_code
            )

            if self._restart_count >= self.MAX_AUTO_RESTARTS:
                logger.error(
                    "Backend has crashed %d times; giving up on auto-restart. "
                    "Check logs/backend.log for the reason.",
                    self._restart_count,
                )
                return

            self._restart_count += 1
            logger.warning(
                "Restarting backend in %.1fs (attempt %d/%d).",
                self.RESTART_DELAY_S, self._restart_count, self.MAX_AUTO_RESTARTS,
            )
            time.sleep(self.RESTART_DELAY_S)

            if self._stopping:
                return
            self._spawn()

    # ------------------------------------------------------------------
    def is_running(self) -> bool:
        return self.process is not None and self.process.poll() is None

    # ------------------------------------------------------------------
    def stop(self) -> None:
        self._stopping = True  # tells the watchdog not to restart

        if self.process:
            try:
                self.process.terminate()
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    logger.warning("Backend did not exit in time; killing it.")
                    self.process.kill()
                    self.process.wait(timeout=5)
            except Exception:
                logger.exception("Error while stopping backend process.")
            finally:
                self.process = None

        if self._log_file:
            try:
                self._log_file.close()
            except Exception:
                pass
            self._log_file = None
