use autocorrect::{LintResult as CoreLintResult};
use libc::{c_char, c_int, c_ulong};
use std::ffi::{CStr, CString};
use std::ptr;

/// Convert Rust String to C string pointer
fn rust_string_to_c_char(s: String) -> *mut c_char {
    match CString::new(s) {
        Ok(c_string) => c_string.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

/// Convert C string pointer to Rust String
unsafe fn c_char_to_rust_string(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    CStr::from_ptr(ptr).to_string_lossy().into_owned()
}

/// Free a C string that was allocated by Rust
#[no_mangle]
pub unsafe extern "C" fn autocorrect_free_string(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

/// Format text using AutoCorrect
/// Returns a C string that must be freed with autocorrect_free_string
#[no_mangle]
pub unsafe extern "C" fn autocorrect_format(text: *const c_char) -> *mut c_char {
    if text.is_null() {
        return ptr::null_mut();
    }
    
    let input = c_char_to_rust_string(text);
    let result = autocorrect::format(&input);
    rust_string_to_c_char(result)
}

/// Format text for a specific file type using AutoCorrect
/// Returns a C string that must be freed with autocorrect_free_string
#[no_mangle]
pub unsafe extern "C" fn autocorrect_format_for(
    text: *const c_char,
    filename: *const c_char,
) -> *mut c_char {
    if text.is_null() || filename.is_null() {
        return ptr::null_mut();
    }
    
    let input = c_char_to_rust_string(text);
    let filename_str = c_char_to_rust_string(filename);
    let result = autocorrect::format_for(&input, &filename_str);
    rust_string_to_c_char(result.out)
}

/// Load configuration for AutoCorrect
#[no_mangle]
pub unsafe extern "C" fn autocorrect_load_config(config_str: *const c_char) -> c_int {
    if config_str.is_null() {
        return -1;
    }
    
    let config = c_char_to_rust_string(config_str);
    match autocorrect::config::load(&config) {
        Ok(_) => 0,
        Err(_) => -1,
    }
}

// For lint operations, we'll need to manage memory for complex structures
// We'll use opaque pointers and accessor functions

/// Opaque handle for LintResult
pub struct LintResultHandle {
    result: CoreLintResult,
}

/// Lint text for a specific file type
/// Returns an opaque handle that must be freed with autocorrect_free_lint_result
#[no_mangle]
pub unsafe extern "C" fn autocorrect_lint_for(
    text: *const c_char,
    filename: *const c_char,
) -> *mut LintResultHandle {
    if text.is_null() || filename.is_null() {
        return ptr::null_mut();
    }
    
    let input = c_char_to_rust_string(text);
    let filename_str = c_char_to_rust_string(filename);
    let result = autocorrect::lint_for(&input, &filename_str);
    
    Box::into_raw(Box::new(LintResultHandle { result }))
}

/// Free a LintResult handle
#[no_mangle]
pub unsafe extern "C" fn autocorrect_free_lint_result(handle: *mut LintResultHandle) {
    if !handle.is_null() {
        drop(Box::from_raw(handle));
    }
}

/// Get the filepath from a LintResult handle
/// Returns a C string that must be freed with autocorrect_free_string
#[no_mangle]
pub unsafe extern "C" fn autocorrect_lint_result_filepath(
    handle: *const LintResultHandle,
) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    
    let handle_ref = &*handle;
    rust_string_to_c_char(handle_ref.result.filepath.clone())
}

/// Get the raw text from a LintResult handle
/// Returns a C string that must be freed with autocorrect_free_string
#[no_mangle]
pub unsafe extern "C" fn autocorrect_lint_result_raw(
    handle: *const LintResultHandle,
) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    
    let handle_ref = &*handle;
    rust_string_to_c_char(handle_ref.result.raw.clone())
}

/// Get the error message from a LintResult handle
/// Returns a C string that must be freed with autocorrect_free_string  
#[no_mangle]
pub unsafe extern "C" fn autocorrect_lint_result_error(
    handle: *const LintResultHandle,
) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    
    let handle_ref = &*handle;
    rust_string_to_c_char(handle_ref.result.error.clone())
}

/// Get the number of lint lines from a LintResult handle
#[no_mangle]
pub unsafe extern "C" fn autocorrect_lint_result_lines_count(
    handle: *const LintResultHandle,
) -> c_ulong {
    if handle.is_null() {
        return 0;
    }
    
    let handle_ref = &*handle;
    handle_ref.result.lines.len() as c_ulong
}

/// Get a specific line result by index
/// Returns the line number (1-based), or 0 if index is out of bounds
#[no_mangle]
pub unsafe extern "C" fn autocorrect_lint_line_number(
    handle: *const LintResultHandle,
    index: c_ulong,
) -> c_ulong {
    if handle.is_null() {
        return 0;
    }
    
    let handle_ref = &*handle;
    if let Some(line) = handle_ref.result.lines.get(index as usize) {
        line.line as c_ulong
    } else {
        0
    }
}

/// Get a specific line column by index
#[no_mangle]
pub unsafe extern "C" fn autocorrect_lint_line_column(
    handle: *const LintResultHandle,
    index: c_ulong,
) -> c_ulong {
    if handle.is_null() {
        return 0;
    }
    
    let handle_ref = &*handle;
    if let Some(line) = handle_ref.result.lines.get(index as usize) {
        line.col as c_ulong
    } else {
        0
    }
}

/// Get the old text for a specific line by index
/// Returns a C string that must be freed with autocorrect_free_string
#[no_mangle]
pub unsafe extern "C" fn autocorrect_lint_line_old(
    handle: *const LintResultHandle,
    index: c_ulong,
) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    
    let handle_ref = &*handle;
    if let Some(line) = handle_ref.result.lines.get(index as usize) {
        rust_string_to_c_char(line.old.clone())
    } else {
        ptr::null_mut()
    }
}

/// Get the new text for a specific line by index
/// Returns a C string that must be freed with autocorrect_free_string
#[no_mangle]
pub unsafe extern "C" fn autocorrect_lint_line_new(
    handle: *const LintResultHandle,
    index: c_ulong,
) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    
    let handle_ref = &*handle;
    if let Some(line) = handle_ref.result.lines.get(index as usize) {
        rust_string_to_c_char(line.new.clone())
    } else {
        ptr::null_mut()
    }
}

/// Get the severity for a specific line by index
/// Returns: 0 = Pass, 1 = Error, 2 = Warning
#[no_mangle]
pub unsafe extern "C" fn autocorrect_lint_line_severity(
    handle: *const LintResultHandle,
    index: c_ulong,
) -> c_int {
    if handle.is_null() {
        return -1;
    }
    
    let handle_ref = &*handle;
    if let Some(line) = handle_ref.result.lines.get(index as usize) {
        line.severity as c_int
    } else {
        -1
    }
}

/// Opaque handle for Ignorer
pub struct IgnorerHandle {
    ignorer: autocorrect::ignorer::Ignorer,
}

/// Create a new Ignorer for a work directory
#[no_mangle]
pub unsafe extern "C" fn autocorrect_new_ignorer(work_dir: *const c_char) -> *mut IgnorerHandle {
    if work_dir.is_null() {
        return ptr::null_mut();
    }
    
    let work_dir_str = c_char_to_rust_string(work_dir);
    let ignorer = autocorrect::ignorer::Ignorer::new(&work_dir_str);
    
    Box::into_raw(Box::new(IgnorerHandle { ignorer }))
}

/// Free an Ignorer handle
#[no_mangle]
pub unsafe extern "C" fn autocorrect_free_ignorer(handle: *mut IgnorerHandle) {
    if !handle.is_null() {
        drop(Box::from_raw(handle));
    }
}

/// Check if a file path is ignored
#[no_mangle]
pub unsafe extern "C" fn autocorrect_ignorer_is_ignored(
    handle: *const IgnorerHandle,
    filepath: *const c_char,
) -> c_int {
    if handle.is_null() || filepath.is_null() {
        return -1;
    }
    
    let handle_ref = &*handle;
    let filepath_str = c_char_to_rust_string(filepath);
    
    if handle_ref.ignorer.is_ignored(&filepath_str) {
        1
    } else {
        0
    }
}