/* cali_shell.h: C ABI between cali-compositor (Zig) and cali-shell (Rust).
 * Keep in sync with shell/src/lib.rs.
 * SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef CALI_SHELL_H
#define CALI_SHELL_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CaliShell CaliShell;

typedef struct {
  float x, y, width, height;
} CaliRect;

typedef struct {
  float size, active_width, spacing;
  unsigned char inactive_opacity;
} CaliDotStyle;

typedef struct {
  float icon_size, padding, spacing, corner_radius;
  unsigned int background; /* 0xRRGGBBAA */
  float running_dot, bottom_margin;
} CaliDockStyle;

typedef enum {
  CALI_MENU_SETTINGS = 1,
  CALI_MENU_LOG_OUT = 2,
  CALI_MENU_RESTART = 3,
  CALI_MENU_POWER_OFF = 4,
} CaliMenuAction;

typedef struct {
  float width, padding, row_height, corner_radius;
  unsigned int background, hover; /* 0xRRGGBBAA */
  float status_icon_size;
} CaliMenuStyle;

typedef struct {
  unsigned char day;
  bool in_month, today;
} CaliDay;

typedef struct {
  unsigned int network; /* 0 unknown, 1 offline, 2 wired, 3 Wi-Fi, 4 connecting */
  bool wifi_available, wifi_enabled, bluetooth_available, bluetooth_enabled;
  float volume; /* 0-1, < 0 = unavailable */
  bool muted;
  float battery;
  bool charging;
  float brightness;
} CaliStatus;

const char *cali_shell_version(void);
CaliShell  *cali_shell_new(void);
bool        cali_shell_start(CaliShell *shell);
void        cali_shell_free(CaliShell *shell);

/* Top bar */
unsigned int cali_shell_panel_height(void);
size_t       cali_shell_clock_text(char *buf, size_t len);

/* Workspaces */
CaliDotStyle cali_shell_workspace_dots_style(void);
size_t cali_shell_workspace_plan(const bool *occupied, size_t n, size_t active,
                                 unsigned int *remove_out, size_t cap,
                                 bool *append_out);

/* Drawing: premultiplied RGBA, rgba is 0xRRGGBBAA */
bool cali_shell_render_rounded_rect(unsigned int width, unsigned int height,
                                    float radius, unsigned int rgba,
                                    unsigned char *buf, size_t len);

/* Icons: premultiplied RGBA size x size; recolor paints symbolic icons rgb (0xRRGGBB) */
bool cali_shell_load_icon(const char *name, unsigned int size, bool recolor,
                          unsigned int rgb, unsigned char *buf, size_t len);

/* Dock */
CaliDockStyle cali_shell_dock_style(void);
const char   *cali_shell_dock_favorite(size_t i);

/* System menu */
CaliMenuStyle cali_shell_menu_style(void);
const char   *cali_shell_menu_entry(size_t i, CaliMenuAction *action);
const char   *cali_shell_status_icon(size_t i);
const char   *cali_shell_status_icons(const CaliStatus *status, size_t i);
const char   *cali_shell_volume_icon(float volume, bool muted);

/* Settings */
unsigned int cali_shell_accent_rgba(const char *name); /* 0xRRGGBBAA */
void         cali_shell_set_clock_options(bool weekday, bool seconds);
void         cali_shell_set_dock_favorites(const char *comma_separated);

/* Calendar (months 1-12, weeks start on Sunday) */
void   cali_shell_calendar_today(int *year, unsigned int *month, unsigned int *day);
bool   cali_shell_calendar_grid(int year, unsigned int month, CaliDay *out /* 42 */);
void   cali_shell_calendar_add_months(int *year, unsigned int *month, int delta);
size_t cali_shell_format_date(int year, unsigned int month, unsigned int day /* 0 = today */,
                              const char *format, char *buf, size_t len);

/* Search: higher is better, -1 = no match */
int cali_shell_search_score(const char *query, const char *text);

/* Screenshots */
size_t cali_shell_screenshot_path(char *buf, size_t len);
bool   cali_shell_save_png(const char *path, unsigned int width, unsigned int height,
                           size_t stride, const unsigned char *data /* premultiplied RGBA */);

/* Lock screen (PAM, checked on a thread) */
size_t cali_shell_current_user(char *buf, size_t len);
bool   cali_shell_auth_start(const char *password);
int    cali_shell_auth_poll(void); /* -1 checking, 1 ok, 0 wrong, -2 idle */

/* Wallpaper */
bool           cali_shell_wallpaper_gradient(const char *name, unsigned int *top, unsigned int *bottom);
unsigned char *cali_shell_load_image(const char *path, unsigned int *width, unsigned int *height);
void           cali_shell_free_image(unsigned char *pixels, size_t len);

/* Keyboard layouts, app folders */
size_t      cali_shell_layout_short_name(const char *layout, char *buf, size_t len);
const char *cali_shell_app_folder(const char *categories);

/* Activities overview */
size_t cali_shell_overview_layout(CaliRect area, const CaliRect *windows,
                                  size_t n, CaliRect *out);

#ifdef __cplusplus
}
#endif

#endif /* CALI_SHELL_H */
