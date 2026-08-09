import json
import os


class ConfigManager:
    def __init__(self, config_file="config.json"):
        self.config_file = config_file
        self.config = {}
        self.load()

    def load(self):
        if os.path.exists(self.config_file):
            with open(self.config_file, "r") as f:
                self.config = json.load(f)
        else:
            self.config = {}
        # FIX (Issue 1): load() must return the parsed configuration.
        # Callers such as app.py do `raw_config = config_manager.load()`
        # and use the return value directly. Without this return
        # statement, load() implicitly returns None, so app.py always
        # ignored config.json and silently fell back to its built-in
        # defaults (e.g. kiosk_mode always defaulting to True regardless
        # of what config.json actually said).
        return self.config

    def save(self):
        with open(self.config_file, "w") as f:
            json.dump(self.config, f, indent=4)

    def get(self, key):
        return self.config.get(key)

    def set(self, key, value):
        self.config[key] = value
        self.save()
