# Writing a Cali extension

An extension is a folder with two things in it:

- `extension.json`, which describes it;
- one program, in any language, that Cali runs while the extension is on.

People install, turn on, configure and remove extensions in **Cali Settings → Extensions**, or with `calictl ext`.

Each extension runs as its own process. If it crashes, Cali restarts it, up to three times a minute. It can't take the desktop down with it.

## extension.json

```json
{
  "id": "cpu-monitor",
  "name": "CPU Monitor",
  "description": "Shows how busy your processor is in the top bar.",
  "version": "1.0",
  "author": "You",
  "exec": "cpu-monitor.py",
  "settings": [
    {"key": "interval", "kind": "number", "default": 2, "min": 1, "max": 30, "step": 1,
     "title": "Update Every", "help": "Seconds between updates"},
    {"key": "style", "kind": "string", "default": "both", "choices": ["both", "text", "icon"],
     "labels": ["Icon and Percentage", "Percentage Only", "Icon Only"], "title": "Show"}
  ]
}
```

- `id`: lowercase letters, digits, dots and dashes.
- `exec`: a file inside the folder. Cali marks it executable when it installs the extension.
- `settings`: optional. Each one has a `kind`:
  - `bool` shows as a switch;
  - `number` shows as a spin button and can use `min`, `max` and `step`;
  - `string` shows as a text field, or as a dropdown when it has `choices` (with optional `labels`).

  Cali Settings builds these controls for you.

## What your program gets

These environment variables are set:

| Variable | Contents |
| --- | --- |
| `CALI_EXTENSION_ID` | the extension's id |
| `CALI_EXTENSION_DIR` | its folder |
| `CALI_EXTENSION_SETTINGS` | a JSON file with the current setting values |

When the user changes a setting, Cali restarts the program, so you only need to read the settings once at start.

## Adding to the top bar

Call the shell on the session bus:

- bus name `org.calide.Shell`
- object path `/org/calide/Shell/Panel`
- interface `org.calide.Shell.Panel`

| Method or signal | What it does |
| --- | --- |
| `SetItem(id, icon, label, tooltip)` | shows or updates an item left of the status icons. `icon` is an icon name or a file path; either it or `label` can be empty. |
| `SetMenu(id, rows)` | gives the item a menu (a list of strings). |
| `RemoveItem(id)` | removes it. |
| signal `Activated(id, index)` | the item was clicked (`index` -1, when it has no menu) or a menu row was picked (`index` 0, 1, …). |

Items belong to your program's bus connection and disappear when it exits.

To show notifications, use the standard freedesktop notification API (`notify-send`, libnotify, …).

## Trying it

```sh
calictl ext install ./my-extension     # a folder, .zip or .tar.gz
calictl ext on my-extension
calictl ext list                       # shows running, or the last error
```

Your program's output goes to cali-extd's log, which is the session log.

[data/extensions/cpu-monitor](../data/extensions/cpu-monitor) is a complete example in about 60 lines of Python.

## Sharing it

Zip the folder (or make a .tar.gz). People install it with **Install from File…**, or paste a link to it into **Install from a Link**.
