#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VitalS Administrator Panel
===============================================================================

A professional, medical-device-style GTK3 control panel for VitalS
administrators. This window is opened after a successful login (see
ui/login.py) and provides:

    Application : start / stop / restart backend and frontend services
    Display     : Kiosk Mode toggle (persisted to config.json)
    Security    : administrator password change
    System      : restart VitalS / reboot / shutdown the Raspberry Pi
    Logs        : view and clear the application log

Architectural rules followed:
    - This module NEVER manipulates backend/frontend processes directly.
      All service control goes through the existing BackendManager /
      FrontendManager instances passed into the constructor.
    - This module NEVER reads or writes config.json directly. All
      configuration access goes through the existing ConfigManager instance
      passed into the constructor.
    - app.py is not imported, modified, or otherwise depended upon. This
      window is self-contained and can be opened by any caller that holds
      references to the three manager instances (see ui/login.py's
      `show_admin_login` for the intended wiring).

Assumed public interfaces (documented here exactly as in app.py, since
these manager classes already exist and are not rewritten):

    ConfigManager(config_path: str)
        .load() -> dict
        .get(key: str, default=None) -> Any        # optional
        .set(key: str, value: Any) -> None          # optional
        .save(config: dict = None) -> None          # optional
    Whichever of (set()+save()) or (load()+save(config)) is available is
    used by `_persist_config_value` below; if neither is present, saving
    fails loudly (an error dialog is shown) rather than silently no-op'ing.

    BackendManager(config: dict) / FrontendManager(config: dict)
        .start() -> None
        .stop()  -> None
        .is_running() -> bool
        .restart() -> None                          # optional; if absent,
                                                      # restart is emulated
                                                      # as stop() + start()

Security note (future hardening): administrator passwords are currently
stored in config.json as plaintext (matching the format already used by
ui/login.py and the project's config.json example). `_on_change_password_
clicked` is written so that switching to a salted hash later only requires
changing how the new password is persisted here and how it is verified in
ui/login.py -- no other part of this file needs to change.
===============================================================================
"""

import os
import sys
import logging
import subprocess
from typing import Any, Callable, Dict, Optional

import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, GLib  # noqa: E402  (must follow gi.require_version)

from core.config_manager import ConfigManager
from core.backend_manager import BackendManager
from core.frontend_manager import FrontendManager


# ---------------------------------------------------------------------------
# Professional medical-device theme (white / light grey / blue accent,
# rounded cards, no dark mode, no neon). Kept local to this module for now;
# if a shared ui/theme.py is introduced later, this constant and
# `_apply_css` can be moved there verbatim and imported by both admin.py
# and login.py instead of each defining their own copy.
# ---------------------------------------------------------------------------
ADMIN_PANEL_CSS = """
window {
    background-color: #eef1f4;
}
label {
    color: #1c2b36;
    font-family: "Segoe UI", "Noto Sans", sans-serif;
}
.vitals-subtitle {
    color: #5b6b76;
    font-size: 12px;
}
.vitals-admin-header {
    background-color: #ffffff;
    border-bottom: 1px solid #d7dde1;
}
.vitals-card {
    background-color: #ffffff;
    border: 1px solid #d7dde1;
    border-radius: 10px;
}
entry {
    border-radius: 6px;
    border: 1px solid #c7d0d6;
    padding: 6px 10px;
    background-color: #ffffff;
}
entry:focus {
    border-color: #0072c6;
}
button {
    border-radius: 6px;
    padding: 6px 16px;
}
.vitals-btn-primary {
    background-color: #0072c6;
    color: #ffffff;
    font-weight: 600;
}
.vitals-btn-primary:hover {
    background-color: #005a9e;
}
.vitals-btn-secondary {
    background-color: #f3f5f7;
    color: #1c2b36;
    border: 1px solid #c7d0d6;
}
.vitals-btn-secondary:hover {
    background-color: #e6eaed;
}
.vitals-btn-danger {
    background-color: #b3261e;
    color: #ffffff;
    font-weight: 600;
}
.vitals-btn-danger:hover {
    background-color: #8f1e17;
}
switch:checked {
    background-color: #0072c6;
}
.vitals-status-dot {
    font-size: 14px;
}
.vitals-status-running {
    color: #1a7a3c;
}
.vitals-status-stopped {
    color: #b3261e;
}
.vitals-status-unknown {
    color: #9aa5ab;
}
"""

# Computed the same way app.py derives its own LOG_DIR/LOG_FILE (project
# root is one directory above ui/), so the Logs section always points at
# the same file app.py's logging setup writes to, without importing app.py.
_PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOG_FILE_PATH = os.path.join(_PROJECT_ROOT, "logs", "app.log")


def _apply_css(widget: Gtk.Widget, css: str) -> None:
    """Loads the given CSS and attaches it to a widget's style context."""
    provider = Gtk.CssProvider()
    provider.load_from_data(css.encode("utf-8"))
    widget.get_style_context().add_provider(
        provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
    )


class ServiceStatusIndicator(Gtk.Box):
    """Small reusable coloured-dot indicator showing a service's run state."""

    def __init__(self) -> None:
        super().__init__(orientation=Gtk.Orientation.HORIZONTAL, spacing=4)
        self._dot = Gtk.Label(label="\u25CF")  # solid circle
        self._dot.get_style_context().add_class("vitals-status-dot")
        self._text = Gtk.Label(label="Unknown")
        self._text.get_style_context().add_class("vitals-subtitle")
        self.pack_start(self._dot, False, False, 0)
        self.pack_start(self._text, False, False, 0)
        self.set_state(None)

    def set_state(self, running: Optional[bool]) -> None:
        context = self._dot.get_style_context()
        for css_class in (
            "vitals-status-running",
            "vitals-status-stopped",
            "vitals-status-unknown",
        ):
            context.remove_class(css_class)

        if running is True:
            context.add_class("vitals-status-running")
            self._text.set_text("Running")
        elif running is False:
            context.add_class("vitals-status-stopped")
            self._text.set_text("Stopped")
        else:
            context.add_class("vitals-status-unknown")
            self._text.set_text("Unknown")


class AdminPanelWindow(Gtk.Window):
    """
    Top-level Administrator Panel window. Owns no business logic itself:
    every action here delegates to BackendManager, FrontendManager, or
    ConfigManager, per the architectural rules in the module docstring.
    """

    STATUS_POLL_INTERVAL_MS = 2000
    RESTART_WAIT_POLL_INTERVAL_MS = 300
    MIN_PASSWORD_LENGTH = 6

    def __init__(
        self,
        config_manager: ConfigManager,
        backend_manager: BackendManager,
        frontend_manager: FrontendManager,
        parent: Optional[Gtk.Window] = None,
        on_close: Optional[Callable[[], None]] = None,
    ) -> None:
        super().__init__(title="VitalS \u2013 Administrator Panel")

        self._logger = logging.getLogger("vitals.ui.admin")
        self._config_manager = config_manager
        self._backend_manager = backend_manager
        self._frontend_manager = frontend_manager
        self._on_close = on_close

        self._status_poll_source_id: Optional[int] = None
        self._restart_wait_source_ids: Dict[str, Optional[int]] = {
            "backend": None,
            "frontend": None,
        }

        if parent is not None:
            self.set_transient_for(parent)
        self.set_default_size(880, 660)
        self.set_position(Gtk.WindowPosition.CENTER)
        _apply_css(self, ADMIN_PANEL_CSS)

        self.connect("destroy", self._on_destroy)

        self._build_ui()
        self._refresh_service_status()
        self._status_poll_source_id = GLib.timeout_add(
            self.STATUS_POLL_INTERVAL_MS, self._on_status_poll_tick
        )

    # ==================================================================
    # UI construction
    # ==================================================================
    def _build_ui(self) -> None:
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self.add(outer)

        outer.pack_start(self._build_header(), False, False, 0)

        scroller = Gtk.ScrolledWindow()
        scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)

        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18)
        content.set_border_width(20)
        scroller.add(content)
        outer.pack_start(scroller, True, True, 0)

        content.pack_start(self._build_application_card(), False, False, 0)
        content.pack_start(self._build_display_card(), False, False, 0)
        content.pack_start(self._build_security_card(), False, False, 0)
        content.pack_start(self._build_system_card(), False, False, 0)
        content.pack_start(self._build_logs_card(), False, False, 0)

    def _build_header(self) -> Gtk.Widget:
        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        header.get_style_context().add_class("vitals-admin-header")
        header.set_border_width(16)

        title = Gtk.Label()
        title.set_markup("<span size='x-large' weight='bold'>Administrator Panel</span>")
        title.set_halign(Gtk.Align.START)

        close_button = Gtk.Button(label="Close")
        close_button.get_style_context().add_class("vitals-btn-secondary")
        close_button.connect("clicked", lambda *_: self.close())

        header.pack_start(title, True, True, 0)
        header.pack_end(close_button, False, False, 0)
        return header

    def _build_card(self, title: str) -> Gtk.Frame:
        """
        Creates a titled "card" frame in the medical-device style and
        returns it. The caller retrieves the inner content box via
        `frame.get_child()` is avoided for clarity -- instead this returns
        both the frame and its content box as a tuple through the
        `card_content` attribute pattern below.
        """
        frame = Gtk.Frame()
        frame.get_style_context().add_class("vitals-card")
        frame.set_shadow_type(Gtk.ShadowType.NONE)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        box.set_border_width(18)

        title_label = Gtk.Label()
        title_label.set_markup(
            f"<span size='medium' weight='bold'>{GLib.markup_escape_text(title)}</span>"
        )
        title_label.set_halign(Gtk.Align.START)
        box.pack_start(title_label, False, False, 0)

        frame.add(box)
        frame.card_content = box  # type: ignore[attr-defined]
        return frame

    # ------------------------------------------------------------------
    # Application card
    # ------------------------------------------------------------------
    def _build_application_card(self) -> Gtk.Widget:
        frame = self._build_card("Application")
        box: Gtk.Box = frame.card_content  # type: ignore[attr-defined]

        backend_row, self._backend_status = self._build_service_row(
            "Backend Service",
            on_start=self._on_start_backend,
            on_stop=self._on_stop_backend,
            on_restart=self._on_restart_backend,
        )
        box.pack_start(backend_row, False, False, 0)

        box.pack_start(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL), False, False, 2)

        frontend_row, self._frontend_status = self._build_service_row(
            "Frontend Service",
            on_start=self._on_start_frontend,
            on_stop=self._on_stop_frontend,
            on_restart=self._on_restart_frontend,
        )
        box.pack_start(frontend_row, False, False, 0)

        return frame

    def _build_service_row(
        self,
        label_text: str,
        on_start: Callable[[], None],
        on_stop: Callable[[], None],
        on_restart: Callable[[], None],
    ) -> "tuple[Gtk.Widget, ServiceStatusIndicator]":
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)

        label = Gtk.Label(label=label_text, xalign=0)
        label.set_hexpand(True)

        status = ServiceStatusIndicator()

        start_btn = Gtk.Button(label="Start")
        stop_btn = Gtk.Button(label="Stop")
        restart_btn = Gtk.Button(label="Restart")
        start_btn.get_style_context().add_class("vitals-btn-primary")
        stop_btn.get_style_context().add_class("vitals-btn-secondary")
        restart_btn.get_style_context().add_class("vitals-btn-secondary")

        start_btn.connect("clicked", lambda *_: on_start())
        stop_btn.connect("clicked", lambda *_: on_stop())
        restart_btn.connect("clicked", lambda *_: on_restart())

        row.pack_start(label, True, True, 0)
        row.pack_start(status, False, False, 0)
        row.pack_start(start_btn, False, False, 0)
        row.pack_start(stop_btn, False, False, 0)
        row.pack_start(restart_btn, False, False, 0)

        return row, status

    # -- Application card actions (delegate to managers only) ----------
    def _on_start_backend(self) -> None:
        self._run_service_action("backend", self._backend_manager, "start")

    def _on_stop_backend(self) -> None:
        self._run_service_action("backend", self._backend_manager, "stop")

    def _on_restart_backend(self) -> None:
        self._restart_service("backend", self._backend_manager)

    def _on_start_frontend(self) -> None:
        self._run_service_action("frontend", self._frontend_manager, "start")

    def _on_stop_frontend(self) -> None:
        self._run_service_action("frontend", self._frontend_manager, "stop")

    def _on_restart_frontend(self) -> None:
        self._restart_service("frontend", self._frontend_manager)

    def _run_service_action(self, name: str, manager: Any, action: str) -> None:
        try:
            getattr(manager, action)()
            self._logger.info("%s: %s requested successfully.", name.capitalize(), action)
        except Exception:
            self._logger.exception("%s: failed to %s.", name.capitalize(), action)
            self._show_error_dialog(
                f"Failed to {action} the {name} service. See application log for details."
            )
        finally:
            self._refresh_service_status()

    def _restart_service(self, name: str, manager: Any) -> None:
        """
        Restarts a service. If the manager exposes a native restart(), it
        is used directly. Otherwise restart is emulated as stop() followed
        by start(), waiting -- via non-blocking GLib polling, never
        time.sleep() -- for is_running() to report False before starting
        again, so a new process is not launched while the old one is still
        shutting down.
        """
        if hasattr(manager, "restart"):
            self._run_service_action(name, manager, "restart")
            return

        if self._restart_wait_source_ids.get(name) is not None:
            return  # a restart is already in progress for this service

        try:
            manager.stop()
            self._logger.info("%s: stop requested as part of restart.", name.capitalize())
        except Exception:
            self._logger.exception("%s: failed to stop during restart.", name.capitalize())
            self._show_error_dialog(
                f"Failed to restart the {name} service. See application log for details."
            )
            self._refresh_service_status()
            return

        self._refresh_service_status()
        source_id = GLib.timeout_add(
            self.RESTART_WAIT_POLL_INTERVAL_MS, self._poll_restart_wait, name, manager
        )
        self._restart_wait_source_ids[name] = source_id

    def _poll_restart_wait(self, name: str, manager: Any) -> bool:
        try:
            still_running = bool(manager.is_running())
        except Exception:
            still_running = False

        if still_running:
            return True  # keep waiting

        self._restart_wait_source_ids[name] = None
        try:
            manager.start()
            self._logger.info("%s: start requested as part of restart.", name.capitalize())
        except Exception:
            self._logger.exception("%s: failed to start during restart.", name.capitalize())
            self._show_error_dialog(
                f"Failed to restart the {name} service. See application log for details."
            )
        finally:
            self._refresh_service_status()
        return False

    # -- Status polling --------------------------------------------------
    def _on_status_poll_tick(self) -> bool:
        self._refresh_service_status()
        return True

    def _refresh_service_status(self) -> None:
        self._backend_status.set_state(self._safe_is_running(self._backend_manager))
        self._frontend_status.set_state(self._safe_is_running(self._frontend_manager))

    @staticmethod
    def _safe_is_running(manager: Any) -> Optional[bool]:
        try:
            return bool(manager.is_running())
        except Exception:
            return None

    # ------------------------------------------------------------------
    # Display card (Kiosk Mode)
    # ------------------------------------------------------------------
    def _build_display_card(self) -> Gtk.Widget:
        frame = self._build_card("Display")
        box: Gtk.Box = frame.card_content  # type: ignore[attr-defined]

        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)

        text_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        text_box.set_hexpand(True)
        kiosk_label = Gtk.Label(label="Kiosk Mode", xalign=0)
        kiosk_description = Gtk.Label(
            label="Fullscreen, locked-down display for clinical use.", xalign=0
        )
        kiosk_description.get_style_context().add_class("vitals-subtitle")
        text_box.pack_start(kiosk_label, False, False, 0)
        text_box.pack_start(kiosk_description, False, False, 0)

        self._kiosk_switch = Gtk.Switch()
        self._kiosk_switch.set_valign(Gtk.Align.CENTER)
        self._kiosk_switch.set_active(bool(self._load_config_value("kiosk_mode", True)))
        self._kiosk_switch.connect("notify::active", self._on_kiosk_mode_toggled)

        row.pack_start(text_box, True, True, 0)
        row.pack_start(self._kiosk_switch, False, False, 0)
        box.pack_start(row, False, False, 0)

        self._kiosk_restart_hint = Gtk.Label()
        self._kiosk_restart_hint.set_markup(
            "<span size='small' foreground='#b3261e'>Restart VitalS to apply changes.</span>"
        )
        self._kiosk_restart_hint.set_halign(Gtk.Align.START)
        self._kiosk_restart_hint.set_no_show_all(True)
        self._kiosk_restart_hint.hide()
        box.pack_start(self._kiosk_restart_hint, False, False, 0)

        return frame

    def _on_kiosk_mode_toggled(self, switch: Gtk.Switch, _param) -> None:
        new_value = switch.get_active()
        try:
            self._persist_config_value("kiosk_mode", new_value)
            self._logger.info("kiosk_mode set to %s via Administrator Panel.", new_value)
            self._kiosk_restart_hint.show()
        except Exception:
            self._logger.exception("Failed to persist kiosk_mode change.")
            self._show_error_dialog(
                "Failed to save Kiosk Mode setting. See application log for details."
            )
            switch.handler_block_by_func(self._on_kiosk_mode_toggled)
            switch.set_active(not new_value)
            switch.handler_unblock_by_func(self._on_kiosk_mode_toggled)

    # ------------------------------------------------------------------
    # Security card (change administrator password)
    # ------------------------------------------------------------------
    def _build_security_card(self) -> Gtk.Widget:
        frame = self._build_card("Security")
        box: Gtk.Box = frame.card_content  # type: ignore[attr-defined]

        grid = Gtk.Grid(column_spacing=12, row_spacing=10)

        current_label = Gtk.Label(label="Current Password", xalign=0)
        self._current_password_entry = self._build_password_entry()

        new_label = Gtk.Label(label="New Password", xalign=0)
        self._new_password_entry = self._build_password_entry()

        confirm_label = Gtk.Label(label="Confirm New Password", xalign=0)
        self._confirm_password_entry = self._build_password_entry()

        grid.attach(current_label, 0, 0, 1, 1)
        grid.attach(self._current_password_entry, 1, 0, 1, 1)
        grid.attach(new_label, 0, 1, 1, 1)
        grid.attach(self._new_password_entry, 1, 1, 1, 1)
        grid.attach(confirm_label, 0, 2, 1, 1)
        grid.attach(self._confirm_password_entry, 1, 2, 1, 1)
        box.pack_start(grid, False, False, 0)

        self._password_feedback = Gtk.Label()
        self._password_feedback.set_halign(Gtk.Align.START)
        self._password_feedback.set_no_show_all(True)
        self._password_feedback.hide()
        box.pack_start(self._password_feedback, False, False, 0)

        save_button = Gtk.Button(label="Change Password")
        save_button.get_style_context().add_class("vitals-btn-primary")
        save_button.set_halign(Gtk.Align.START)
        save_button.connect("clicked", self._on_change_password_clicked)
        box.pack_start(save_button, False, False, 0)

        return frame

    def _build_password_entry(self) -> Gtk.Entry:
        entry = Gtk.Entry()
        entry.set_visibility(False)
        entry.set_hexpand(True)
        entry.set_icon_from_icon_name(Gtk.EntryIconPosition.SECONDARY, "view-reveal-symbolic")
        entry.set_icon_tooltip_text(Gtk.EntryIconPosition.SECONDARY, "Show password")
        entry.connect("icon-press", self._on_toggle_password_visibility)
        return entry

    def _on_toggle_password_visibility(self, entry: Gtk.Entry, _icon_pos, _event) -> None:
        visible = entry.get_visibility()
        entry.set_visibility(not visible)
        entry.set_icon_from_icon_name(
            Gtk.EntryIconPosition.SECONDARY,
            "view-conceal-symbolic" if not visible else "view-reveal-symbolic",
        )

    def _on_change_password_clicked(self, *_args) -> None:
        current = self._current_password_entry.get_text()
        new = self._new_password_entry.get_text()
        confirm = self._confirm_password_entry.get_text()

        expected_current = self._load_config_value("admin_password", "")

        if not expected_current:
            self._set_password_feedback(
                "Administrator password is not configured in config.json.", is_error=True
            )
            return

        if current != expected_current:
            self._set_password_feedback("Current password is incorrect.", is_error=True)
            return

        if len(new) < self.MIN_PASSWORD_LENGTH:
            self._set_password_feedback(
                f"New password must be at least {self.MIN_PASSWORD_LENGTH} characters.",
                is_error=True,
            )
            return

        if new != confirm:
            self._set_password_feedback(
                "New password and confirmation do not match.", is_error=True
            )
            return

        try:
            # Future hardening: persist a salted hash instead of plaintext
            # once ui/login.py's verification is upgraded accordingly (see
            # the module docstring's security note).
            self._persist_config_value("admin_password", new)
            self._logger.info("Administrator password changed via Administrator Panel.")
            self._set_password_feedback("Password changed successfully.", is_error=False)
            self._current_password_entry.set_text("")
            self._new_password_entry.set_text("")
            self._confirm_password_entry.set_text("")
        except Exception:
            self._logger.exception("Failed to persist new administrator password.")
            self._set_password_feedback(
                "Failed to save new password. See application log for details.", is_error=True
            )

    def _set_password_feedback(self, message: str, is_error: bool) -> None:
        color = "#b3261e" if is_error else "#1a7a3c"
        self._password_feedback.set_markup(
            f"<span size='small' foreground='{color}'>{GLib.markup_escape_text(message)}</span>"
        )
        self._password_feedback.show()

    # ------------------------------------------------------------------
    # Configuration access helpers (all config I/O goes through
    # ConfigManager -- this class never touches config.json directly)
    # ------------------------------------------------------------------
    def _load_config_value(self, key: str, default: Any = None) -> Any:
        try:
            config = self._config_manager.load()
            return config.get(key, default)
        except AttributeError:
            if hasattr(self._config_manager, "get"):
                return self._config_manager.get(key, default)
            return default
        except Exception:
            self._logger.exception("Failed to read '%s' from configuration.", key)
            return default

    def _persist_config_value(self, key: str, value: Any) -> None:
        """
        Persists a single key/value pair via ConfigManager. Supports either
        of ConfigManager's assumed save mechanisms (see module docstring).
        Raises if neither mechanism is available, so the caller can surface
        a clear error rather than silently failing to save.
        """
        if hasattr(self._config_manager, "set") and hasattr(self._config_manager, "save"):
            self._config_manager.set(key, value)
            self._config_manager.save()
            return

        if hasattr(self._config_manager, "load") and hasattr(self._config_manager, "save"):
            config = self._config_manager.load()
            config[key] = value
            self._config_manager.save(config)
            return

        raise RuntimeError(
            "ConfigManager does not expose a supported save mechanism "
            "(expected set()+save() or load()+save(config))."
        )

    # ------------------------------------------------------------------
    # System card (restart VitalS / reboot / shutdown)
    # ------------------------------------------------------------------
    def _build_system_card(self) -> Gtk.Widget:
        frame = self._build_card("System")
        box: Gtk.Box = frame.card_content  # type: ignore[attr-defined]

        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)

        restart_btn = Gtk.Button(label="Restart VitalS")
        reboot_btn = Gtk.Button(label="Reboot Raspberry Pi")
        shutdown_btn = Gtk.Button(label="Shutdown Raspberry Pi")

        restart_btn.get_style_context().add_class("vitals-btn-secondary")
        reboot_btn.get_style_context().add_class("vitals-btn-secondary")
        shutdown_btn.get_style_context().add_class("vitals-btn-danger")

        restart_btn.connect("clicked", self._on_restart_vitals_clicked)
        reboot_btn.connect("clicked", self._on_reboot_pi_clicked)
        shutdown_btn.connect("clicked", self._on_shutdown_pi_clicked)

        row.pack_start(restart_btn, False, False, 0)
        row.pack_start(reboot_btn, False, False, 0)
        row.pack_start(shutdown_btn, False, False, 0)
        box.pack_start(row, False, False, 0)

        return frame

    def _confirm(self, primary_text: str, secondary_text: str = "") -> bool:
        dialog = Gtk.MessageDialog(
            transient_for=self,
            modal=True,
            message_type=Gtk.MessageType.WARNING,
            buttons=Gtk.ButtonsType.YES_NO,
            text=primary_text,
        )
        if secondary_text:
            dialog.format_secondary_text(secondary_text)
        response = dialog.run()
        dialog.destroy()
        return response == Gtk.ResponseType.YES

    def _on_restart_vitals_clicked(self, *_args) -> None:
        if not self._confirm(
            "Restart VitalS?",
            "The application will stop and start again immediately. "
            "Any unsaved state in the dashboard may be lost.",
        ):
            return
        self._logger.info("Administrator requested VitalS restart.")
        self._restart_vitals()

    def _on_reboot_pi_clicked(self, *_args) -> None:
        if not self._confirm(
            "Reboot Raspberry Pi?",
            "The entire device will restart. This may take a minute or more.",
        ):
            return
        self._logger.info("Administrator requested Raspberry Pi reboot.")
        self._run_system_command(["sudo", "systemctl", "reboot"], "reboot")

    def _on_shutdown_pi_clicked(self, *_args) -> None:
        if not self._confirm(
            "Shutdown Raspberry Pi?",
            "The device will power off completely and must be turned back "
            "on manually.",
        ):
            return
        self._logger.info("Administrator requested Raspberry Pi shutdown.")
        self._run_system_command(["sudo", "systemctl", "poweroff"], "shutdown")

    def _restart_vitals(self) -> None:
        """
        Stops the frontend and backend via their managers, then re-executes
        the current Python process in place. Because the Administrator
        Panel runs inside the same process as app.py, this restarts the
        entire VitalS application -- not just this window -- without this
        module touching any manager internals beyond the documented
        start()/stop() interface.
        """
        try:
            self._frontend_manager.stop()
        except Exception:
            self._logger.exception("Failed to stop frontend before restart.")
        try:
            self._backend_manager.stop()
        except Exception:
            self._logger.exception("Failed to stop backend before restart.")

        self._logger.info("Re-executing VitalS process for restart.")
        try:
            os.execv(sys.executable, [sys.executable] + sys.argv)
        except Exception:
            self._logger.exception("Failed to re-exec VitalS process.")
            self._show_error_dialog(
                "Failed to restart VitalS automatically. Please restart it manually."
            )

    def _run_system_command(self, command: list, action_name: str) -> None:
        try:
            subprocess.run(command, check=True)
        except Exception:
            self._logger.exception("Failed to execute system %s command.", action_name)
            self._show_error_dialog(
                f"Failed to {action_name} the Raspberry Pi. Ensure this "
                "application has the required system permissions."
            )

    # ------------------------------------------------------------------
    # Logs card
    # ------------------------------------------------------------------
    def _build_logs_card(self) -> Gtk.Widget:
        frame = self._build_card("Logs")
        box: Gtk.Box = frame.card_content  # type: ignore[attr-defined]

        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)

        open_btn = Gtk.Button(label="Open Application Log")
        clear_btn = Gtk.Button(label="Clear Log")
        open_btn.get_style_context().add_class("vitals-btn-secondary")
        clear_btn.get_style_context().add_class("vitals-btn-secondary")

        open_btn.connect("clicked", self._on_open_log_clicked)
        clear_btn.connect("clicked", self._on_clear_log_clicked)

        row.pack_start(open_btn, False, False, 0)
        row.pack_start(clear_btn, False, False, 0)
        box.pack_start(row, False, False, 0)

        path_label = Gtk.Label(label=LOG_FILE_PATH, xalign=0)
        path_label.get_style_context().add_class("vitals-subtitle")
        path_label.set_selectable(True)
        box.pack_start(path_label, False, False, 0)

        return frame

    def _on_open_log_clicked(self, *_args) -> None:
        try:
            contents = self._read_log_file()
        except Exception:
            self._logger.exception("Failed to read application log.")
            self._show_error_dialog("Failed to open application log. See console for details.")
            return
        self._show_log_viewer(contents)

    @staticmethod
    def _read_log_file() -> str:
        if not os.path.isfile(LOG_FILE_PATH):
            return "Log file not found yet. It will be created once VitalS logs an event."
        with open(LOG_FILE_PATH, "r", encoding="utf-8", errors="replace") as log_file:
            return log_file.read()

    def _show_log_viewer(self, contents: str) -> None:
        dialog = Gtk.Dialog(title="Application Log", transient_for=self, modal=True)
        dialog.set_default_size(760, 520)
        dialog.add_button("Close", Gtk.ResponseType.CLOSE)

        scroller = Gtk.ScrolledWindow()
        scroller.set_hexpand(True)
        scroller.set_vexpand(True)

        text_view = Gtk.TextView()
        text_view.set_editable(False)
        text_view.set_cursor_visible(False)
        text_view.set_monospace(True)
        text_view.get_buffer().set_text(contents)
        # Scroll to the most recent log entries by default.
        end_iter = text_view.get_buffer().get_end_iter()
        text_view.scroll_to_iter(end_iter, 0.0, False, 0.0, 0.0)

        scroller.add(text_view)
        content_area = dialog.get_content_area()
        content_area.set_border_width(12)
        content_area.pack_start(scroller, True, True, 0)

        dialog.show_all()
        dialog.run()
        dialog.destroy()

    def _on_clear_log_clicked(self, *_args) -> None:
        if not self._confirm(
            "Clear application log?",
            "This will permanently delete all current log entries.",
        ):
            return
        try:
            self._truncate_log_file()
            self._logger.info("Application log cleared via Administrator Panel.")
        except Exception:
            self._logger.exception("Failed to clear application log.")
            self._show_error_dialog("Failed to clear application log. See console for details.")

    @staticmethod
    def _truncate_log_file() -> None:
        """
        Truncates the application log in place. If a handler for this exact
        log file is currently attached to the "vitals" logger (as app.py's
        logging setup does), its open stream is truncated directly so the
        running process's file handle stays valid; otherwise the file is
        simply reopened in write mode.
        """
        vitals_logger = logging.getLogger("vitals")
        truncated_via_handler = False

        for handler in vitals_logger.handlers:
            stream = getattr(handler, "stream", None)
            base_filename = getattr(handler, "baseFilename", None)
            if (
                stream is not None
                and base_filename
                and os.path.abspath(base_filename) == os.path.abspath(LOG_FILE_PATH)
            ):
                stream.seek(0)
                stream.truncate()
                stream.flush()
                truncated_via_handler = True

        if not truncated_via_handler:
            os.makedirs(os.path.dirname(LOG_FILE_PATH), exist_ok=True)
            with open(LOG_FILE_PATH, "w", encoding="utf-8"):
                pass

    # ------------------------------------------------------------------
    # Shared dialogs / cleanup
    # ------------------------------------------------------------------
    def _show_error_dialog(self, message: str) -> None:
        dialog = Gtk.MessageDialog(
            transient_for=self,
            modal=True,
            message_type=Gtk.MessageType.ERROR,
            buttons=Gtk.ButtonsType.OK,
            text="An error occurred",
        )
        dialog.format_secondary_text(message)
        dialog.run()
        dialog.destroy()

    def _on_destroy(self, *_args) -> None:
        if self._status_poll_source_id is not None:
            try:
                GLib.source_remove(self._status_poll_source_id)
            except Exception:
                pass
            self._status_poll_source_id = None

        for name, source_id in list(self._restart_wait_source_ids.items()):
            if source_id is not None:
                try:
                    GLib.source_remove(source_id)
                except Exception:
                    pass
                self._restart_wait_source_ids[name] = None

        if self._on_close:
            self._on_close()
