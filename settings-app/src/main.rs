//! Cali Settings: customize the Cali desktop. Talks to cali-settingsd
//! (org.calide.SettingsDaemon on the session bus); changes apply right away.

use std::collections::HashMap;

use adw::prelude::*;
use gtk::{gio, glib};

const APP_ID: &str = "org.calide.Settings";

/// (setting value, label) in the order shown.
const ACCENTS: [(&str, &str); 10] = [
    ("coral", "Coral"),
    ("blue", "Blue"),
    ("teal", "Teal"),
    ("green", "Green"),
    ("yellow", "Yellow"),
    ("orange", "Orange"),
    ("red", "Red"),
    ("pink", "Pink"),
    ("purple", "Purple"),
    ("slate", "Slate"),
];

fn main() -> glib::ExitCode {
    let app = adw::Application::builder().application_id(APP_ID).build();
    app.connect_activate(build_window);
    app.run()
}

/// The connection to cali-settingsd.
#[derive(Clone)]
struct Settings {
    proxy: gio::DBusProxy,
}

impl Settings {
    fn connect() -> Option<(Settings, HashMap<String, glib::Variant>)> {
        let proxy = gio::DBusProxy::for_bus_sync(
            gio::BusType::Session,
            gio::DBusProxyFlags::DO_NOT_AUTO_START,
            None,
            "org.calide.SettingsDaemon",
            "/org/calide/Settings",
            "org.calide.Settings",
            None::<&gio::Cancellable>,
        )
        .ok()?;
        let reply = proxy
            .call_sync("GetAll", None, gio::DBusCallFlags::NONE, 2000, None::<&gio::Cancellable>)
            .ok()?;
        let dict = reply.child_value(0);
        let mut values = HashMap::new();
        for i in 0..dict.n_children() {
            let entry = dict.child_value(i);
            if let (Some(key), Some(value)) = (entry.child_value(0).str().map(str::to_owned), entry.child_value(1).as_variant()) {
                values.insert(key, value);
            }
        }
        Some((Settings { proxy }, values))
    }

    fn set(&self, key: &str, value: glib::Variant) {
        let params = glib::Variant::tuple_from_iter([key.to_variant(), glib::Variant::from_variant(&value)]);
        self.proxy.call(
            "Set",
            Some(&params),
            gio::DBusCallFlags::NONE,
            2000,
            None::<&gio::Cancellable>,
            |result| {
                if let Err(err) = result {
                    eprintln!("cali-settings: {err}");
                }
            },
        );
    }
}

/// Built-in wallpapers: (setting value, label). The last entry is a picked image.
const WALLPAPERS: [(&str, &str); 4] = [
    ("cali-dusk", "Dusk"),
    ("cali-day", "Day"),
    ("cali-night", "Night"),
    ("cali-forest", "Forest"),
];

fn list_row(settings: &Settings, values: &HashMap<String, glib::Variant>, key: &'static str, title: &str, subtitle: &str) -> adw::EntryRow {
    let row = adw::EntryRow::builder().title(title).show_apply_button(true).build();
    let list = values.get(key).and_then(|v| v.get::<Vec<String>>()).unwrap_or_default();
    row.set_text(&list.join(", "));
    row.set_tooltip_text(Some(subtitle));
    let settings = settings.clone();
    row.connect_apply(move |row| {
        let items: Vec<String> = row.text().split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect();
        settings.set(key, items.to_variant());
    });
    row
}

fn wallpaper_group(settings: &Settings, values: &HashMap<String, glib::Variant>) -> adw::PreferencesGroup {
    let group = adw::PreferencesGroup::builder().title("Background").build();
    let mut labels: Vec<&str> = WALLPAPERS.iter().map(|(_, l)| *l).collect();
    labels.push("Custom Image");
    let combo = adw::ComboRow::builder().title("Wallpaper").model(&gtk::StringList::new(&labels)).build();
    let current = values.get("wallpaper").and_then(|v| v.get::<String>()).unwrap_or_default();
    let custom = WALLPAPERS.len() as u32;
    combo.set_selected(WALLPAPERS.iter().position(|(v, _)| *v == current).map(|i| i as u32).unwrap_or(custom));
    if !current.is_empty() && !current.starts_with("cali-") {
        combo.set_subtitle(&current);
    }

    let pick = gtk::Button::builder().label("Choose Image\u{2026}").valign(gtk::Align::Center).build();
    {
        let settings = settings.clone();
        let combo = combo.clone();
        pick.connect_clicked(move |button| {
            let filter = gtk::FileFilter::new();
            filter.set_name(Some("Images"));
            filter.add_mime_type("image/png");
            filter.add_mime_type("image/jpeg");
            let filters = gio::ListStore::new::<gtk::FileFilter>();
            filters.append(&filter);
            let dialog = gtk::FileDialog::builder().title("Choose a Wallpaper").filters(&filters).build();
            let window = button.root().and_downcast::<gtk::Window>();
            let settings = settings.clone();
            let combo = combo.clone();
            dialog.open(window.as_ref(), None::<&gio::Cancellable>, move |result| {
                if let Some(path) = result.ok().and_then(|f| f.path()) {
                    let path = path.to_string_lossy().to_string();
                    settings.set("wallpaper", path.to_variant());
                    combo.set_subtitle(&path);
                    combo.set_selected(WALLPAPERS.len() as u32);
                }
            });
        });
    }
    combo.add_suffix(&pick);
    {
        let settings = settings.clone();
        combo.connect_selected_notify(move |row| {
            if let Some((value, _)) = WALLPAPERS.get(row.selected() as usize) {
                settings.set("wallpaper", value.to_variant());
                row.set_subtitle("");
            }
        });
    }
    group.add(&combo);
    group
}

fn switch_row(settings: &Settings, values: &HashMap<String, glib::Variant>, key: &'static str, title: &str, subtitle: &str) -> adw::SwitchRow {
    let row = adw::SwitchRow::builder().title(title).subtitle(subtitle).build();
    row.set_active(values.get(key).and_then(|v| v.get::<bool>()).unwrap_or(false));
    let settings = settings.clone();
    row.connect_active_notify(move |r| settings.set(key, r.is_active().to_variant()));
    row
}

fn build_window(app: &adw::Application) {
    let window = adw::ApplicationWindow::builder()
        .application(app)
        .title("Cali Settings")
        .default_width(560)
        .default_height(680)
        .build();

    let page = match Settings::connect() {
        Some((settings, values)) => settings_page(&settings, &values),
        None => adw::StatusPage::builder()
            .icon_name("dialog-warning-symbolic")
            .title("Cali Isn't Running")
            .description("Cali Settings changes the Cali desktop. Start a Cali session, then try again.")
            .build()
            .upcast(),
    };

    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&adw::HeaderBar::new());
    toolbar.set_content(Some(&page));
    window.set_content(Some(&toolbar));
    window.present();
}

fn settings_page(settings: &Settings, values: &HashMap<String, glib::Variant>) -> gtk::Widget {
    let page = adw::PreferencesPage::new();

    // Appearance
    let appearance = adw::PreferencesGroup::builder().title("Appearance").build();

    let names = gtk::StringList::new(&ACCENTS.map(|(_, label)| label));
    let accent = adw::ComboRow::builder()
        .title("Accent Color")
        .subtitle("Used for highlights, toggles and today in the calendar")
        .model(&names)
        .build();
    let current = values.get("accent-color").and_then(|v| v.get::<String>()).unwrap_or_default();
    accent.set_selected(ACCENTS.iter().position(|(v, _)| *v == current).unwrap_or(0) as u32);
    {
        let settings = settings.clone();
        accent.connect_selected_notify(move |row| {
            if let Some((value, _)) = ACCENTS.get(row.selected() as usize) {
                settings.set("accent-color", value.to_variant());
            }
        });
    }
    appearance.add(&accent);
    appearance.add(&switch_row(settings, values, "dark-style", "Dark Style", "Ask apps to use their dark look"));

    let speed = adw::SpinRow::with_range(0.0, 3.0, 0.25);
    speed.set_title("Animation Speed");
    speed.set_subtitle("1 is normal, 0 turns animations off");
    speed.set_digits(2);
    speed.set_value(values.get("animation-speed").and_then(|v| v.get::<f64>()).unwrap_or(1.0));
    {
        let settings = settings.clone();
        speed.connect_value_notify(move |row| settings.set("animation-speed", row.value().to_variant()));
    }
    appearance.add(&speed);
    page.add(&appearance);
    page.add(&wallpaper_group(settings, values));

    // Top bar
    let bar = adw::PreferencesGroup::builder().title("Top Bar").build();
    bar.add(&switch_row(settings, values, "clock-show-weekday", "Show Weekday", "Like “Sun Nov 22”"));
    bar.add(&switch_row(settings, values, "clock-show-seconds", "Show Seconds", "Update the clock every second"));
    page.add(&bar);

    // Behavior
    let behavior = adw::PreferencesGroup::builder().title("Behavior").build();
    behavior.add(&switch_row(settings, values, "hot-corner", "Hot Corner", "Open the overview by pushing the pointer into the top-left corner"));
    page.add(&behavior);

    // Notifications
    let notify = adw::PreferencesGroup::builder().title("Notifications").build();
    notify.add(&switch_row(settings, values, "do-not-disturb", "Do Not Disturb", "Hide banners; notifications still go in the list under the clock"));
    page.add(&notify);

    // Screen and lock
    let screen = adw::PreferencesGroup::builder().title("Screen").build();
    let idle = adw::SpinRow::with_range(0.0, 120.0, 1.0);
    idle.set_title("Blank Screen After");
    idle.set_subtitle("Minutes without input (0 = never)");
    idle.set_value(values.get("idle-delay").and_then(|v| v.get::<f64>()).unwrap_or(5.0));
    {
        let settings = settings.clone();
        idle.connect_value_notify(move |row| settings.set("idle-delay", row.value().to_variant()));
    }
    screen.add(&idle);
    screen.add(&switch_row(settings, values, "lock-on-idle", "Lock When Blank", "Ask for your password after the screen blanks (Super+L locks any time)"));
    page.add(&screen);

    // Keyboard
    let keyboard = adw::PreferencesGroup::builder()
        .title("Keyboard")
        .description("Layouts by xkb name, separated by commas (for example: us, de, fr). Super+Space switches.")
        .build();
    keyboard.add(&list_row(settings, values, "keyboard-layouts", "Layouts", "us, de, us+dvorak, ..."));
    page.add(&keyboard);

    // Dock
    let dock = adw::PreferencesGroup::builder()
        .title("Dock")
        .description("Apps pinned to the dock, as desktop file names separated by commas")
        .build();
    let favorites = adw::EntryRow::builder().title("Favorite Apps").show_apply_button(true).build();
    let list = values.get("dock-favorites").and_then(|v| v.get::<Vec<String>>()).unwrap_or_default();
    favorites.set_text(&list.join(", "));
    {
        let settings = settings.clone();
        favorites.connect_apply(move |row| {
            let ids: Vec<String> = row
                .text()
                .split(',')
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();
            settings.set("dock-favorites", ids.to_variant());
        });
    }
    dock.add(&favorites);
    page.add(&dock);

    page.upcast()
}
