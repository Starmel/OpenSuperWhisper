#ifndef AUTOCORRECT_SWIFT_H
#define AUTOCORRECT_SWIFT_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>

// Forward declarations for opaque types
typedef struct LintResultHandle LintResultHandle;
typedef struct IgnorerHandle IgnorerHandle;

// String management
void autocorrect_free_string(char* s);

// Core formatting functions
char* autocorrect_format(const char* text);
char* autocorrect_format_for(const char* text, const char* filename);

// Configuration
int autocorrect_load_config(const char* config_str);

// Lint operations
LintResultHandle* autocorrect_lint_for(const char* text, const char* filename);
void autocorrect_free_lint_result(LintResultHandle* handle);

// LintResult accessors
char* autocorrect_lint_result_filepath(const LintResultHandle* handle);
char* autocorrect_lint_result_raw(const LintResultHandle* handle);
char* autocorrect_lint_result_error(const LintResultHandle* handle);
unsigned long autocorrect_lint_result_lines_count(const LintResultHandle* handle);

// Line result accessors (by index)
unsigned long autocorrect_lint_line_number(const LintResultHandle* handle, unsigned long index);
unsigned long autocorrect_lint_line_column(const LintResultHandle* handle, unsigned long index);
char* autocorrect_lint_line_old(const LintResultHandle* handle, unsigned long index);
char* autocorrect_lint_line_new(const LintResultHandle* handle, unsigned long index);
int autocorrect_lint_line_severity(const LintResultHandle* handle, unsigned long index);

// Ignorer operations
IgnorerHandle* autocorrect_new_ignorer(const char* work_dir);
void autocorrect_free_ignorer(IgnorerHandle* handle);
int autocorrect_ignorer_is_ignored(const IgnorerHandle* handle, const char* filepath);

#ifdef __cplusplus
}
#endif

#endif // AUTOCORRECT_SWIFT_H