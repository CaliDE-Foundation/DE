//! Cali Settings: customize the Cali desktop. Talks to cali-settingsd
//! (org.calide.SettingsDaemon on the session bus); changes apply right away.
//! The pages are built from the schema cali-settingsd describes, so every
//! setting it knows shows up here. Advanced settings appear with the
//! Advanced toggle.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use adw::prelude::*;
use gtk::{gio, glib};
use serde::Deserialize;

const APP_ID: &str = "org.calide.Settings";

/// Pages in order, with their icons.
const PAGES: [(&str, &str); 6] = [
    ("Appearance", "applications-graphics-symbolic"),
    ("Top Bar", "view-continuous-symbolic"),
    ("Overview", "view-app-grid-symbolic"),
    ("Windows", "window-new-symbolic"),
    ("Tiling", "view-grid-symbolic"),
    ("Behavior", "preferences-system-symbolic"),
];

/// Groups in the order they appear on their page.
const GROUP_ORDER: [&str; 19] = [
    "Style", "Background", "Bar", "Clock", "Indicators", "Overview", "App Grid", "Dock", "Calendar",
    "Animations", "Behavior", "Workspaces", "Layout", "Dwindle", "Scrolling", "Switching", "Notifications",
    "Screen", "Keyboard",
];

/// Built-in wallpapers: (setting value, label).
const WALLPAPERS: [(&str, &str); 4] = [("cali-dusk", "Dusk"), ("cali-day", "Day"), ("cali-night", "Night"), ("cali-forest", "Forest")];

#[derive(Deserialize, Clone)]
struct Entry {
    key: String,
    kind: String,
    title: String,
    help: String,
    page: String,
    group: String,
    advanced: bool,
    #[serde(default)]
    choices: Vec<String>,
    #[serde(default)]
    labels: Vec<String>,
    min: f64,
    max: f64,
    step: f64,
}

type AdvancedRows = Rc<RefCell<Vec<(gtk::Widget, adw::PreferencesGroup)>>>;

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
    fn connect() -> Option<(Settings, Vec<Entry>, HashMap<String, glib::Variant>)> {
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
        let call = |method: &str| proxy.call_sync(method, None, gio::DBusCallFlags::NONE, 2000, None::<&gio::Cancellable>).ok();
        let schema_reply = call("GetSchema")?;
        let schema: Vec<Entry> = serde_json::from_str(schema_reply.child_value(0).str()?).ok()?;
        let dict = call("GetAll")?.child_value(0);
        let mut values = HashMap::new();
        for i in 0..dict.n_children() {
            let entry = dict.child_value(i);
            if let (Some(key), Some(value)) = (entry.child_value(0).str().map(str::to_owned), entry.child_value(1).as_variant()) {
                values.insert(key, value);
            }
        }
        Some((Settings { proxy }, schema, values))
    }

    fn set(&self, key: &str, value: glib::Variant) {
        let params = glib::Variant::tuple_from_iter([key.to_variant(), glib::Variant::from_variant(&value)]);
        self.proxy.call("Set", Some(&params), gio::DBusCallFlags::NONE, 2000, None::<&gio::Cancellable>, |result| {
            if let Err(err) = result {
                eprintln!("cali-settings: {err}");
            }
        });
    }
}

fn build_window(app: &adw::Application) {
    let window = adw::ApplicationWindow::builder()
        .application(app)
        .title("Cali Settings")
        .default_width(1000)
        .default_height(780)
        .build();

    let toolbar = adw::ToolbarView::new();
    let header = adw::HeaderBar::new();
    toolbar.add_top_bar(&header);

    match Settings::connect() {
        Some((settings, schema, values)) => {
            let stack = adw::ViewStack::new();
            let advanced_rows: AdvancedRows = Rc::default();
            for (page_name, icon) in PAGES {
                let page = build_page(&settings, &schema, &values, page_name, &advanced_rows);
                stack.add_titled_with_icon(&page, Some(page_name), page_name, icon);
            }
            let switcher = adw::ViewSwitcher::builder().stack(&stack).policy(adw::ViewSwitcherPolicy::Wide).build();
            header.set_title_widget(Some(&switcher));

            // Default shows the common settings; Advanced shows everything.
            let advanced = gtk::ToggleButton::builder().label("Advanced").tooltip_text("Show every setting").build();
            header.pack_end(&advanced);
            let rows = advanced_rows.clone();
            let apply = move |on: bool| {
                for (row, _) in rows.borrow().iter() {
                    row.set_visible(on);
                }
                for (_, group) in rows.borrow().iter() {
                    group.set_visible(on || group_has_visible_rows(group));
                }
            };
            apply(std::env::var("CALI_SETTINGS_ADVANCED").is_ok());
            advanced.set_active(std::env::var("CALI_SETTINGS_ADVANCED").is_ok());
            advanced.connect_toggled(move |b| apply(b.is_active()));
            if let Ok(page) = std::env::var("CALI_SETTINGS_PAGE") {
                if let Some((name, _)) = PAGES.iter().find(|(name, _)| name.eq_ignore_ascii_case(&page)) {
                    stack.set_visible_child_name(name);
                }
            }
            toolbar.set_content(Some(&stack));
        }
        None => toolbar.set_content(Some(
            &adw::StatusPage::builder()
                .icon_name("dialog-warning-symbolic")
                .title("Cali Isn't Running")
                .description("Cali Settings changes the Cali desktop. Start a Cali session, then try again.")
                .build(),
        )),
    }
    window.set_content(Some(&toolbar));
    window.present();
}

/// Whether a group still shows a row (in Default mode).
fn group_has_visible_rows(group: &adw::PreferencesGroup) -> bool {
    fn any_visible_row(w: &gtk::Widget) -> bool {
        if w.is::<adw::PreferencesRow>() {
            return w.is_visible();
        }
        let mut child = w.first_child();
        while let Some(c) = child {
            if any_visible_row(&c) {
                return true;
            }
            child = c.next_sibling();
        }
        false
    }
    any_visible_row(group.upcast_ref())
}

fn build_page(settings: &Settings, schema: &[Entry], values: &HashMap<String, glib::Variant>, page_name: &str, advanced_rows: &AdvancedRows) -> adw::PreferencesPage {
    let page = adw::PreferencesPage::new();
    let mut entries: Vec<&Entry> = schema.iter().filter(|e| e.page == page_name).collect();
    let rank = |g: &str| GROUP_ORDER.iter().position(|x| *x == g).unwrap_or(GROUP_ORDER.len());
    entries.sort_by(|a, b| rank(&a.group).cmp(&rank(&b.group)).then(a.advanced.cmp(&b.advanced)).then(a.title.cmp(&b.title)));

    let mut groups: Vec<(String, adw::PreferencesGroup)> = Vec::new();
    for entry in entries {
        let group = match groups.iter().find(|(name, _)| *name == entry.group) {
            Some((_, g)) => g.clone(),
            None => {
                let g = adw::PreferencesGroup::builder().title(entry.group.as_str()).build();
                page.add(&g);
                groups.push((entry.group.clone(), g.clone()));
                g
            }
        };
        let row = build_row(settings, entry, values.get(&entry.key));
        group.add(&row);
        if entry.advanced {
            advanced_rows.borrow_mut().push((row, group.clone()));
        }
    }
    page
}

fn build_row(settings: &Settings, e: &Entry, value: Option<&glib::Variant>) -> gtk::Widget {
    if e.key == "wallpaper" {
        return wallpaper_row(settings, e, value).upcast();
    }
    let key = e.key.clone();
    let settings = settings.clone();
    match e.kind.as_str() {
        "bool" => {
            let row = adw::SwitchRow::builder().title(e.title.as_str()).subtitle(e.help.as_str()).build();
            row.set_active(value.and_then(|v| v.get::<bool>()).unwrap_or(false));
            row.connect_active_notify(move |r| settings.set(&key, r.is_active().to_variant()));
            row.upcast()
        }
        "number" => {
            let row = adw::SpinRow::with_range(e.min, e.max, e.step);
            row.set_title(&e.title);
            row.set_subtitle(&e.help);
            row.set_digits(if e.step < 1.0 { 2 } else { 0 });
            row.set_value(value.and_then(|v| v.get::<f64>()).unwrap_or(e.min));
            row.connect_value_notify(move |r| settings.set(&key, r.value().to_variant()));
            row.upcast()
        }
        "string" if !e.choices.is_empty() => {
            let labels: Vec<&str> =
                if e.labels.len() == e.choices.len() { e.labels.iter().map(String::as_str).collect() } else { e.choices.iter().map(String::as_str).collect() };
            let row = adw::ComboRow::builder().title(e.title.as_str()).subtitle(e.help.as_str()).model(&gtk::StringList::new(&labels)).build();
            let current = value.and_then(|v| v.get::<String>()).unwrap_or_default();
            row.set_selected(e.choices.iter().position(|c| *c == current).unwrap_or(0) as u32);
            let choices = e.choices.clone();
            row.connect_selected_notify(move |r| {
                if let Some(choice) = choices.get(r.selected() as usize) {
                    settings.set(&key, choice.to_variant());
                }
            });
            row.upcast()
        }
        "list" => {
            let row = adw::EntryRow::builder().title(e.title.as_str()).show_apply_button(true).tooltip_text(e.help.as_str()).build();
            row.set_text(&value.and_then(|v| v.get::<Vec<String>>()).unwrap_or_default().join(", "));
            row.connect_apply(move |r| {
                let items: Vec<String> = r.text().split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect();
                settings.set(&key, items.to_variant());
            });
            row.upcast()
        }
        _ => {
            let row = adw::EntryRow::builder().title(e.title.as_str()).show_apply_button(true).tooltip_text(e.help.as_str()).build();
            row.set_text(&value.and_then(|v| v.get::<String>()).unwrap_or_default());
            row.connect_apply(move |r| settings.set(&key, r.text().to_string().to_variant()));
            row.upcast()
        }
    }
}

fn wallpaper_row(settings: &Settings, e: &Entry, value: Option<&glib::Variant>) -> adw::ComboRow {
    let mut labels: Vec<&str> = WALLPAPERS.iter().map(|(_, l)| *l).collect();
    labels.push("Custom Image");
    let combo = adw::ComboRow::builder().title(e.title.as_str()).model(&gtk::StringList::new(&labels)).build();
    let current = value.and_then(|v| v.get::<String>()).unwrap_or_default();
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
    let settings = settings.clone();
    combo.connect_selected_notify(move |row| {
        if let Some((value, _)) = WALLPAPERS.get(row.selected() as usize) {
            settings.set("wallpaper", value.to_variant());
            row.set_subtitle("");
        }
    });
    combo
}
