//! The Extensions page: everything about extensions in one place. Install
//! from a file or a link, turn them on and off, change their settings and
//! remove them. Talks to cali-extd (org.calide.Extensions).

use std::cell::RefCell;
use std::rc::Rc;

use adw::prelude::*;
use gtk::{gio, glib};
use serde::Deserialize;
use serde_json::Value;

#[derive(Deserialize, Clone)]
struct ExtSetting {
    key: String,
    kind: String,
    title: String,
    #[serde(default)]
    help: String,
    #[serde(default)]
    min: f64,
    #[serde(default)]
    max: f64,
    #[serde(default)]
    step: f64,
    #[serde(default)]
    choices: Vec<String>,
    #[serde(default)]
    labels: Vec<String>,
}

#[derive(Deserialize, Clone)]
struct Ext {
    id: String,
    name: String,
    #[serde(default)]
    description: String,
    #[serde(default)]
    version: String,
    #[serde(default)]
    author: String,
    #[serde(default)]
    settings: Vec<ExtSetting>,
    system: bool,
    enabled: bool,
    #[serde(default)]
    error: String,
    #[serde(default)]
    values: serde_json::Map<String, Value>,
}

fn proxy() -> Option<gio::DBusProxy> {
    gio::DBusProxy::for_bus_sync(
        gio::BusType::Session,
        gio::DBusProxyFlags::DO_NOT_AUTO_START,
        None,
        "org.calide.Extensions",
        "/org/calide/Extensions",
        "org.calide.Extensions",
        None::<&gio::Cancellable>,
    )
    .ok()
}

fn list(proxy: &gio::DBusProxy) -> Vec<Ext> {
    proxy
        .call_sync("List", None, gio::DBusCallFlags::NONE, 3000, None::<&gio::Cancellable>)
        .ok()
        .and_then(|reply| reply.child_value(0).str().map(str::to_owned))
        .and_then(|json| serde_json::from_str(&json).ok())
        .unwrap_or_default()
}

/// Calls a method and shows an error toast if it fails.
fn call(proxy: &gio::DBusProxy, toasts: &adw::ToastOverlay, method: &str, params: glib::Variant, done: Option<Box<dyn Fn(glib::Variant)>>) {
    let toasts = toasts.clone();
    proxy.call(method, Some(&params), gio::DBusCallFlags::NONE, 60_000, None::<&gio::Cancellable>, move |result| match result {
        Ok(reply) => {
            if let Some(f) = done {
                f(reply)
            }
        }
        Err(err) => {
            let msg = gio::DBusError::remote_error(&err).map(|_| err.message().to_string()).unwrap_or_else(|| err.to_string());
            let msg = msg.rsplit(": ").next().unwrap_or(&msg).to_string();
            toasts.add_toast(adw::Toast::new(&msg));
        }
    });
}

/// The page, wrapped in a toast overlay for errors and confirmations.
pub fn page() -> gtk::Widget {
    let toasts = adw::ToastOverlay::new();
    let Some(proxy) = proxy() else {
        let status = adw::StatusPage::builder()
            .icon_name("application-x-addon-symbolic")
            .title("Extensions Aren't Available")
            .description("The extension service (cali-extd) isn't running. Log out and back in to start it.")
            .build();
        toasts.set_child(Some(&status));
        return toasts.upcast();
    };

    let page = adw::PreferencesPage::new();
    let installed: Rc<RefCell<Option<adw::PreferencesGroup>>> = Rc::default();
    toasts.set_child(Some(&page));

    // Install from a file or folder, or from a link.
    let actions = adw::PreferencesGroup::builder()
        .title("Get Extensions")
        .description("Extensions add things to Cali, like items in the top bar. Each runs on its own, so a broken one can't take the desktop down.")
        .build();
    let from_file = adw::ButtonRow::builder().title("Install from File\u{2026}").start_icon_name("document-open-symbolic").build();
    let link = adw::EntryRow::builder().title("Install from a Link (.zip or .tar.gz)").show_apply_button(true).build();
    actions.add(&from_file);
    actions.add(&link);
    page.add(&actions);

    let refresh: Rc<dyn Fn()> = {
        let page = page.clone();
        let installed = installed.clone();
        let proxy = proxy.clone();
        let toasts = toasts.clone();
        Rc::new(move || {
            let group = adw::PreferencesGroup::builder().title("Installed").build();
            let exts = list(&proxy);
            if exts.is_empty() {
                group.add(&adw::ActionRow::builder().title("No extensions yet").subtitle("Install one above").build());
            }
            for ext in exts {
                group.add(&ext_row(&proxy, &toasts, ext));
            }
            if let Some(old) = installed.borrow_mut().take() {
                page.remove(&old);
            }
            page.add(&group);
            *installed.borrow_mut() = Some(group);
        })
    };
    refresh();

    // Rebuild when anything changes (here, from calictl, or a crash).
    {
        let refresh = refresh.clone();
        proxy.connect_local("g-signal", false, move |args| {
            if args.get(2).and_then(|v| v.get::<String>().ok()).as_deref() == Some("Changed") {
                refresh();
            }
            None
        });
    }

    {
        let proxy = proxy.clone();
        let toasts = toasts.clone();
        from_file.connect_activated(move |row| {
            let filter = gtk::FileFilter::new();
            filter.set_name(Some("Extensions"));
            filter.add_suffix("zip");
            filter.add_suffix("tar.gz");
            filter.add_suffix("tgz");
            filter.add_suffix("json");
            let filters = gio::ListStore::new::<gtk::FileFilter>();
            filters.append(&filter);
            let dialog = gtk::FileDialog::builder()
                .title("Install an Extension (a .zip, .tar.gz, or its extension.json)")
                .filters(&filters)
                .build();
            let window = row.root().and_downcast::<gtk::Window>();
            let proxy = proxy.clone();
            let toasts = toasts.clone();
            dialog.open(window.as_ref(), None::<&gio::Cancellable>, move |result| {
                let Some(mut path) = result.ok().and_then(|f| f.path()) else { return };
                // Picking extension.json installs the folder it's in.
                if path.file_name().is_some_and(|n| n == "extension.json") {
                    path.pop();
                }
                install(&proxy, &toasts, path.to_string_lossy().to_string());
            });
        });
    }
    {
        let proxy = proxy.clone();
        let toasts = toasts.clone();
        link.connect_apply(move |row| {
            let url = row.text().trim().to_string();
            if !url.starts_with("https://") {
                toasts.add_toast(adw::Toast::new("Use an https:// link"));
                return;
            }
            row.set_text("");
            install(&proxy, &toasts, url);
        });
    }
    toasts.upcast()
}

fn install(proxy: &gio::DBusProxy, toasts: &adw::ToastOverlay, source: String) {
    let t = toasts.clone();
    call(
        proxy,
        toasts,
        "Install",
        (source,).to_variant(),
        Some(Box::new(move |reply| {
            let id = reply.child_value(0).get::<String>().unwrap_or_default();
            t.add_toast(adw::Toast::new(&format!("Installed {id}. Turn it on below.")));
        })),
    );
}

/// One extension: a switch, and when expanded its settings and Remove.
fn ext_row(proxy: &gio::DBusProxy, toasts: &adw::ToastOverlay, ext: Ext) -> adw::ExpanderRow {
    let mut subtitle = glib::markup_escape_text(&ext.description).to_string();
    if !ext.error.is_empty() {
        subtitle = format!("<span foreground=\"#e01b24\">{}</span>", glib::markup_escape_text(&ext.error));
    }
    let row = adw::ExpanderRow::builder().title(glib::markup_escape_text(&ext.name).as_str()).subtitle(subtitle).build();
    let switch = gtk::Switch::builder().active(ext.enabled).valign(gtk::Align::Center).build();
    switch.update_property(&[gtk::accessible::Property::Label(&format!("Turn {} on or off", ext.name))]);
    {
        let proxy = proxy.clone();
        let toasts = toasts.clone();
        let id = ext.id.clone();
        switch.connect_state_set(move |_, on| {
            call(&proxy, &toasts, "SetEnabled", (id.clone(), on).to_variant(), None);
            glib::Propagation::Proceed
        });
    }
    row.add_suffix(&switch);

    for s in &ext.settings {
        row.add_row(&setting_row(proxy, toasts, &ext.id, s, ext.values.get(&s.key)));
    }

    let mut about = format!("Version {}", if ext.version.is_empty() { "?" } else { &ext.version });
    if !ext.author.is_empty() {
        about.push_str(&format!(" \u{b7} by {}", ext.author));
    }
    if ext.system {
        about.push_str(" \u{b7} installed for everyone");
    }
    let info = adw::ActionRow::builder().title(glib::markup_escape_text(&about).as_str()).subtitle(ext.id.as_str()).build();
    if !ext.system {
        let remove = gtk::Button::builder().label("Remove").valign(gtk::Align::Center).css_classes(["destructive-action"]).build();
        let proxy = proxy.clone();
        let toasts = toasts.clone();
        let id = ext.id.clone();
        remove.connect_clicked(move |_| call(&proxy, &toasts, "Remove", (id.clone(),).to_variant(), None));
        info.add_suffix(&remove);
    }
    row.add_row(&info);
    row
}

fn setting_row(proxy: &gio::DBusProxy, toasts: &adw::ToastOverlay, id: &str, s: &ExtSetting, value: Option<&Value>) -> gtk::Widget {
    let set = {
        let proxy = proxy.clone();
        let toasts = toasts.clone();
        let id = id.to_string();
        let key = s.key.clone();
        move |v: glib::Variant| {
            let params = glib::Variant::tuple_from_iter([id.to_variant(), key.to_variant(), glib::Variant::from_variant(&v)]);
            call(&proxy, &toasts, "SetSetting", params, None);
        }
    };
    match s.kind.as_str() {
        "bool" => {
            let row = adw::SwitchRow::builder().title(s.title.as_str()).subtitle(s.help.as_str()).build();
            row.set_active(value.and_then(Value::as_bool).unwrap_or(false));
            row.connect_active_notify(move |r| set(r.is_active().to_variant()));
            row.upcast()
        }
        "number" => {
            let step = if s.step > 0.0 { s.step } else { 1.0 };
            let row = adw::SpinRow::with_range(s.min, if s.max > s.min { s.max } else { s.min + 1000.0 }, step);
            row.set_title(&s.title);
            row.set_subtitle(&s.help);
            row.set_digits(if step < 1.0 { 2 } else { 0 });
            row.set_value(value.and_then(Value::as_f64).unwrap_or(s.min));
            row.connect_value_notify(move |r| set(r.value().to_variant()));
            row.upcast()
        }
        _ if !s.choices.is_empty() => {
            let labels: Vec<&str> = if s.labels.len() == s.choices.len() { s.labels.iter().map(String::as_str).collect() } else { s.choices.iter().map(String::as_str).collect() };
            let row = adw::ComboRow::builder().title(s.title.as_str()).subtitle(s.help.as_str()).model(&gtk::StringList::new(&labels)).build();
            let current = value.and_then(Value::as_str).unwrap_or_default();
            row.set_selected(s.choices.iter().position(|c| c == current).unwrap_or(0) as u32);
            let choices = s.choices.clone();
            row.connect_selected_notify(move |r| {
                if let Some(c) = choices.get(r.selected() as usize) {
                    set(c.to_variant());
                }
            });
            row.upcast()
        }
        _ => {
            let row = adw::EntryRow::builder().title(s.title.as_str()).show_apply_button(true).build();
            row.set_text(value.and_then(Value::as_str).unwrap_or_default());
            row.connect_apply(move |r| set(r.text().to_string().to_variant()));
            row.upcast()
        }
    }
}
