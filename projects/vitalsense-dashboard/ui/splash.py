import gi

gi.require_version("Gtk", "3.0")

from gi.repository import Gtk, GLib


class SplashScreen(Gtk.Window):

    def __init__(self):

        Gtk.Window.__init__(self, title="VitalS")

        self.set_default_size(700, 400)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_resizable(False)
        self.set_border_width(20)

        box = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=20
        )

        self.add(box)

        title = Gtk.Label()
        title.set_markup(
            "<span font='28' weight='bold'>🩺 VitalS</span>"
        )

        subtitle = Gtk.Label()
        subtitle.set_markup(
            "<span font='14'>Hospital Bed Ulcer Prevention System</span>"
        )

        self.status = Gtk.Label(
            label="Initializing..."
        )

        self.progress = Gtk.ProgressBar()

        box.pack_start(title, False, False, 10)
        box.pack_start(subtitle, False, False, 0)
        box.pack_start(self.status, False, False, 20)
        box.pack_start(self.progress, False, False, 0)

        self.show_all()

    def set_status(self, text):

        self.status.set_text(text)

    def set_progress(self, value):

        self.progress.set_fraction(value)
