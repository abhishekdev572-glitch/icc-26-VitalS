#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VitalS Administrator Login
===============================================================================

A centered, modal GTK3 dialog that collects administrator credentials and
verifies them against config.json (via the existing ConfigManager). This
module owns UI + authentication flow only; it never manipulates backend or
frontend processes and never reads/writes config.json directly -- all
configuration access goes through ConfigManager.

Flow implemented here:
    Administrator button (elsewhere) --> show_admin_login() --> AdminLoginDialog
        --> on success --> ui.admin.AdminPanelWindow
        --> on cancel  --> caller's on_close callback (if any)

This module does not modify app.py. It is designed to be invoked from
wherever the "Administrator" trigger ends up living (e.g. a future
WebKit2 script-message handler wired into app.py's `launch_admin_login`
extension point) by calling `show_admin_login(...)`.

Assumed public interface of ConfigManager (already exists, not rewritten):
    ConfigManager(config_path: str)
        .load() -> dict                      # parses config.json
        .get(key: str, default=None) -> Any  # optional convenience accessor

Security note (future hardening):
    config.json currently stores "admin_password" as plaintext, matching
    the example given in the project requirements. `_verify_credentials`
    below is written so that upgrading to a salted hash (e.g. via
    `hashlib.pbkdf2_hmac` or `bcrypt`) later only requires changing the
    comparison inside that one method -- no other code in this file, or in
    ui/admin.py, needs to change.
===============================================================================
"""

import logging
from typing import Callable, Optional

import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, GLib  # noqa: E402  (must follow gi.require_version)

from core.config_manager import ConfigManager


# ---------------------------------------------------------------------------
# Professional medical-device theme (white / light grey / blue accent).
# Kept local to this module for now; if a shared ui/theme.py is introduced
# later, this constant and `_apply_css` can be moved there verbatim and
# imported by both login.py and admin.py.
# ---------------------------------------------------------------------------
LOGIN_DIALOG_CSS = """
window {
    background-color: #eef1f4;
}
label {
    color: #1c2b36;
    font-family: "Segoe UI", "Noto Sans", sans-serif;
}
.vitals-subtitle {
    color: #5b6b76;
    font-size: 13px;
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
.vitals-error-label {
    color: #b3261e;
    font-size: 12px;
}
"""


def _apply_css(widget: Gtk.Widget, css: str) -> None:
    """Loads the given CSS and attaches it to a widget's style context."""
    provider = Gtk.CssProvider()
    provider.load_from_data(css.encode("utf-8"))
    widget.get_style_context().add_provider(
        provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
    )


class AdminAuthenticationError(Exception):
    """Raised when administrator credentials cannot be verified at all
    (e.g. config.json is missing the required keys), as distinct from a
    simple wrong-password case."""


class AdminLoginDialog(Gtk.Dialog):
    """
    Centered modal login dialog for administrator access.

    Responsibilities (and only these):
        - Collect username / password.
        - Verify them against config.json via ConfigManager.
        - Invoke on_success() / on_cancel() callbacks; the caller decides
          what happens next (this class does not know about AdminPanelWindow
          directly -- see `show_admin_login` below for that wiring).
    """

    MAX_FAILED_ATTEMPTS = 5
    LOCKOUT_SECONDS = 30

    def __init__(
        self,
        config_manager: ConfigManager,
        parent: Optional[Gtk.Window] = None,
        on_success: Optional[Callable[[], None]] = None,
        on_cancel: Optional[Callable[[], None]] = None,
    ) -> None:
        super().__init__(title="Administrator Login", transient_for=parent)
        self.set_modal(True)

        self._logger = logging.getLogger("vitals.ui.login")
        self._config_manager = config_manager
        self._on_success = on_success
        self._on_cancel = on_cancel

        self._failed_attempts = 0
        self._lockout_source_id: Optional[int] = None

        self.set_default_size(380, -1)
        self.set_resizable(False)
        self.set_position(Gtk.WindowPosition.CENTER_ALWAYS)
        self.set_border_width(0)
        _apply_css(self, LOGIN_DIALOG_CSS)

        self._build_ui()
        self.connect("response", self._on_response)
        self.connect("delete-event", self._on_delete_event)

    # ------------------------------------------------------------------
    # UI construction
    # ------------------------------------------------------------------
    def _build_ui(self) -> None:
        content_area = self.get_content_area()
        content_area.set_border_width(24)
        content_area.set_spacing(16)

        header_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        header_box.set_halign(Gtk.Align.CENTER)

        icon = Gtk.Image.new_from_icon_name(
            "dialog-password-symbolic", Gtk.IconSize.DIALOG
        )
        title_label = Gtk.Label()
        title_label.set_markup(
            "<span size='large' weight='bold'>Administrator Login</span>"
        )
        subtitle_label = Gtk.Label(label="Enter your administrator credentials to continue.")
        subtitle_label.get_style_context().add_class("vitals-subtitle")

        header_box.pack_start(icon, False, False, 0)
        header_box.pack_start(title_label, False, False, 0)
        header_box.pack_start(subtitle_label, False, False, 0)
        content_area.pack_start(header_box, False, False, 0)

        form_grid = Gtk.Grid(column_spacing=12, row_spacing=10)
        form_grid.set_margin_top(8)

        username_label = Gtk.Label(label="Username", xalign=0)
        self._username_entry = Gtk.Entry()
        self._username_entry.set_placeholder_text("admin")
        self._username_entry.set_activates_default(True)
        self._username_entry.set_hexpand(True)

        password_label = Gtk.Label(label="Password", xalign=0)
        self._password_entry = Gtk.Entry()
        self._password_entry.set_visibility(False)
        self._password_entry.set_placeholder_text("Password")
        self._password_entry.set_activates_default(True)
        self._password_entry.set_hexpand(True)
        self._password_entry.set_icon_from_icon_name(
            Gtk.EntryIconPosition.SECONDARY, "view-reveal-symbolic"
        )
        self._password_entry.set_icon_tooltip_text(
            Gtk.EntryIconPosition.SECONDARY, "Show password"
        )
        self._password_entry.connect("icon-press", self._on_toggle_password_visibility)

        form_grid.attach(username_label, 0, 0, 1, 1)
        form_grid.attach(self._username_entry, 1, 0, 1, 1)
        form_grid.attach(password_label, 0, 1, 1, 1)
        form_grid.attach(self._password_entry, 1, 1, 1, 1)
        content_area.pack_start(form_grid, False, False, 0)

        self._error_label = Gtk.Label()
        self._error_label.set_line_wrap(True)
        self._error_label.set_max_width_chars(40)
        self._error_label.get_style_context().add_class("vitals-error-label")
        self._error_label.set_no_show_all(True)
        content_area.pack_start(self._error_label, False, False, 0)

        self._cancel_button = self.add_button("Cancel", Gtk.ResponseType.CANCEL)
        self._login_button = self.add_button("Login", Gtk.ResponseType.OK)
        self._login_button.get_style_context().add_class("vitals-btn-primary")
        self.set_default_response(Gtk.ResponseType.OK)

        self.show_all()
        self._error_label.hide()
        self._username_entry.grab_focus()

    # ------------------------------------------------------------------
    # Event handlers
    # ------------------------------------------------------------------
    def _on_toggle_password_visibility(
        self, entry: Gtk.Entry, _icon_pos, _event
    ) -> None:
        visible = entry.get_visibility()
        entry.set_visibility(not visible)
        entry.set_icon_from_icon_name(
            Gtk.EntryIconPosition.SECONDARY,
            "view-conceal-symbolic" if not visible else "view-reveal-symbolic",
        )

    def _on_response(self, _dialog, response_id) -> None:
        if response_id == Gtk.ResponseType.OK:
            self._attempt_login()
        else:
            self._cancel()

    def _on_delete_event(self, *_args) -> bool:
        # Route window-close (the "X" button) through the same cancel path
        # as clicking Cancel, rather than destroying the dialog silently.
        self.response(Gtk.ResponseType.CANCEL)
        return True

    # ------------------------------------------------------------------
    # Authentication
    # ------------------------------------------------------------------
    def _attempt_login(self) -> None:
        if self._lockout_source_id is not None:
            return  # currently locked out; ignore further attempts

        username = self._username_entry.get_text().strip()
        password = self._password_entry.get_text()

        try:
            authenticated = self._verify_credentials(username, password)
        except AdminAuthenticationError as exc:
            self._logger.error("Administrator login misconfigured: %s", exc)
            self._show_error(str(exc))
            return
        except Exception:
            self._logger.exception("Unexpected error verifying administrator credentials.")
            self._show_error("Unable to verify credentials. See application log.")
            return

        if authenticated:
            self._logger.info("Administrator login succeeded for user '%s'.", username)
            self.destroy()
            if self._on_success:
                self._on_success()
            return

        self._failed_attempts += 1
        self._logger.warning(
            "Administrator login failed for user '%s' (attempt %d/%d).",
            username, self._failed_attempts, self.MAX_FAILED_ATTEMPTS,
        )
        self._password_entry.set_text("")
        self._password_entry.grab_focus()

        if self._failed_attempts >= self.MAX_FAILED_ATTEMPTS:
            self._enter_lockout()
        else:
            remaining = self.MAX_FAILED_ATTEMPTS - self._failed_attempts
            self._show_error(f"Invalid username or password. {remaining} attempt(s) remaining.")

    def _verify_credentials(self, username: str, password: str) -> bool:
        """
        Reads admin_username / admin_password from config.json (via
        ConfigManager) and compares against the supplied values. Credentials
        are never hardcoded in source; config.json is the single source of
        truth, exactly as required.
        """
        config = self._load_config_safely()
        expected_username = config.get("admin_username", "")
        expected_password = config.get("admin_password", "")

        if not expected_username or not expected_password:
            raise AdminAuthenticationError(
                "Administrator credentials are not configured in config.json."
            )

        return username == expected_username and password == expected_password

    def _load_config_safely(self) -> dict:
        try:
            return self._config_manager.load() or {}
        except AttributeError:
            # Fallback for a ConfigManager variant exposing only .get().
            if hasattr(self._config_manager, "get"):
                return {
                    "admin_username": self._config_manager.get("admin_username", ""),
                    "admin_password": self._config_manager.get("admin_password", ""),
                }
            return {}

    # ------------------------------------------------------------------
    # Lockout handling (basic brute-force protection)
    # ------------------------------------------------------------------
    def _enter_lockout(self) -> None:
        self._login_button.set_sensitive(False)
        self._show_error(
            f"Too many failed attempts. Login disabled for {self.LOCKOUT_SECONDS} seconds."
        )
        self._lockout_source_id = GLib.timeout_add_seconds(
            self.LOCKOUT_SECONDS, self._end_lockout
        )

    def _end_lockout(self) -> bool:
        self._failed_attempts = 0
        self._lockout_source_id = None
        if self._login_button:
            self._login_button.set_sensitive(True)
        self._hide_error()
        return False  # one-shot timer

    # ------------------------------------------------------------------
    # UI feedback helpers
    # ------------------------------------------------------------------
    def _show_error(self, message: str) -> None:
        self._error_label.set_text(message)
        self._error_label.show()

    def _hide_error(self) -> None:
        self._error_label.hide()

    def _cancel(self) -> None:
        self._logger.info("Administrator login cancelled.")
        self.destroy()
        if self._on_cancel:
            self._on_cancel()


def show_admin_login(
    config_manager: ConfigManager,
    backend_manager,
    frontend_manager,
    parent: Optional[Gtk.Window] = None,
    on_close: Optional[Callable[[], None]] = None,
) -> AdminLoginDialog:
    """
    Convenience entry point implementing the complete
    "Administrator button -> Login -> Administrator Panel" flow.

    Intended to be called from wherever the Administrator trigger ends up
    living (e.g. a future dashboard button handled through a WebKit2
    script-message handler wired into app.py). Calling this function is
    the only integration point required; app.py itself is not modified.

    Args:
        config_manager: existing ConfigManager instance (shared with app.py).
        backend_manager: existing BackendManager instance (shared with app.py).
        frontend_manager: existing FrontendManager instance (shared with app.py).
        parent: window to center the login dialog over, if any.
        on_close: called when the flow ends without opening the admin panel
            (i.e. the operator cancelled the login), and also when the
            Administrator Panel itself is later closed.

    Returns:
        The AdminLoginDialog instance (already shown), in case the caller
        needs a reference to it (e.g. to track it for cleanup).
    """
    logger = logging.getLogger("vitals.ui.login")

    def _open_admin_panel() -> None:
        # Deferred import: ui.admin does not import ui.login, so this is
        # not strictly required to avoid a cycle, but keeping the import
        # local documents the intent that AdminLoginDialog itself has no
        # compile-time dependency on the admin panel implementation.
        from ui.admin import AdminPanelWindow

        try:
            panel = AdminPanelWindow(
                config_manager=config_manager,
                backend_manager=backend_manager,
                frontend_manager=frontend_manager,
                parent=parent,
                on_close=on_close,
            )
            panel.show_all()
        except Exception:
            logger.exception("Failed to open Administrator Panel after successful login.")

    dialog = AdminLoginDialog(
        config_manager=config_manager,
        parent=parent,
        on_success=_open_admin_panel,
        on_cancel=on_close,
    )
    dialog.show_all()
    return dialog