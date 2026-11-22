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

    // Top bar
    let bar = adw::PreferencesGroup::builder().title("Top Bar").build();
    bar.add(&switch_row(settings, values, "clock-show-weekday", "Show Weekday", "Like “Sun Nov 22”"));
    bar.add(&switch_row(settings, values, "clock-show-seconds", "Show Seconds", "Update the clock every second"));
    page.add(&bar);

    // Behavior
    let behavior = adw::PreferencesGroup::builder().title("Behavior").build();
    behavior.add(&switch_row(settings, values, "hot-corner", "Hot Corner", "Open the overview by pushing the pointer into the top-left corner"));
    page.add(&behavior);

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
