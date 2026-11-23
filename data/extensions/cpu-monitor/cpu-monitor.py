#!/usr/bin/env python3
"""CPU Monitor: a Cali extension, and an example of how to write one.

Cali runs this program while the extension is on. It talks to the shell
over D-Bus (org.calide.Shell.Panel) and reads its settings from the JSON
file in $CALI_EXTENSION_SETTINGS; Cali restarts it when they change.
"""
import json
import os
import subprocess

from gi.repository import Gio, GLib

SHELL = "org.calide.Shell"
PATH = "/org/calide/Shell/Panel"
IFACE = "org.calide.Shell.Panel"
ITEM = "cpu"

with open(os.environ["CALI_EXTENSION_SETTINGS"]) as f:
    settings = json.load(f)

bus = Gio.bus_get_sync(Gio.BusType.SESSION)


def call(method, args):
    bus.call_sync(SHELL, PATH, IFACE, method, args, None, Gio.DBusCallFlags.NONE, -1)


def cpu_times():
    with open("/proc/stat") as f:
        fields = [int(x) for x in f.readline().split()[1:]]
    idle = fields[3] + fields[4]  # idle + iowait
    return idle, sum(fields)


last = cpu_times()


def update():
    global last
    now = cpu_times()
    idle, total = now[0] - last[0], now[1] - last[1]
    last = now
    busy = 0 if total == 0 else round(100 * (total - idle) / total)
    style = settings["style"]
    icon = "utilities-system-monitor-symbolic" if style != "text" else ""
    label = f"{busy}%" if style != "icon" else ""
    call("SetItem", GLib.Variant("(ssss)", (ITEM, icon, label, f"Processor {busy}% busy")))
    return True


def on_signal(_conn, _sender, _path, _iface, _signal, params):
    item, row = params.unpack()
    if item == ITEM and row == 0:
        subprocess.Popen(["gnome-system-monitor"])


update()
call("SetMenu", GLib.Variant("(sas)", (ITEM, ["Open System Monitor"])))
bus.signal_subscribe(SHELL, IFACE, "Activated", PATH, None, Gio.DBusSignalFlags.NONE, on_signal)
GLib.timeout_add_seconds(int(settings["interval"]), update)
GLib.MainLoop().run()
