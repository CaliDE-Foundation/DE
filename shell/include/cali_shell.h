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

/* Activities overview */
size_t cali_shell_overview_layout(CaliRect area, const CaliRect *windows,
                                  size_t n, CaliRect *out);

#ifdef __cplusplus
}
#endif

#endif /* CALI_SHELL_H */
