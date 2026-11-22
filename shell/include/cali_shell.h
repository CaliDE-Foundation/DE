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

const char *cali_shell_version(void);
CaliShell  *cali_shell_new(void);
bool        cali_shell_start(CaliShell *shell);
void        cali_shell_free(CaliShell *shell);

/* Top bar */
unsigned int cali_shell_panel_height(void);
size_t       cali_shell_clock_text(char *buf, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* CALI_SHELL_H */
