import gi
import time
import threading
import urllib.request

gi.require_version("Gtk", "3.0")
gi.require_version("WebKit2", "4.1")

from gi.repository import Gtk, WebKit2, GLib

from core.backend_manager import BackendManager
from core.frontend_manager import FrontendManager
from core.config_manager import ConfigManager


class VitalS(Gtk.Window):

    def __init__(self):
        super().__init__(title="VitalS")

        self.set_default_size(1400, 850)
        self.connect("destroy", self.on_close)

        self.config = ConfigManager()
        self.backend = BackendManager()
        self.frontend = FrontendManager()

        self.webview = WebKit2.WebView()
        self.add(self.webview)

        self.show_all()

        threading.Thread(target=self.start_services, daemon=True).start()

    def start_services(self):

        self.backend.start()

        self.frontend.start()

        while True:
            try:
                urllib.request.urlopen("http://127.0.0.1:8080", timeout=1)
                break
            except:
                time.sleep(1)

        GLib.idle_add(
            self.webview.load_uri,
            "http://127.0.0.1:8080"
        )

    def on_close(self, widget):

        self.backend.stop()
        self.frontend.stop()

        Gtk.main_quit()


window = VitalS()
Gtk.main()
