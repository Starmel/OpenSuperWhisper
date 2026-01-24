#!/bin/bash

# Script to manage keyboard layouts for testing
# Usage:
#   ./manage_keyboard_layouts.sh setup    - Save current layouts and install test layouts
#   ./manage_keyboard_layouts.sh restore  - Restore original layouts
#   ./manage_keyboard_layouts.sh list     - List currently enabled layouts
#
# This script uses macOS TIS (Text Input Source) API to enable/disable
# keyboard layouts immediately without requiring logout/login.

BACKUP_FILE="/tmp/keyboard_layouts_backup.txt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_HELPER="/tmp/input_source_manager.swift"

# Test layouts to install
TEST_LAYOUTS=(
    # Basic
    "com.apple.keylayout.US"
    "com.apple.keylayout.ABC"
    "com.apple.keylayout.British"
    "com.apple.keylayout.USInternational-PC"
    "com.apple.keylayout.Colemak"
    # Dvorak
    "com.apple.keylayout.Dvorak"
    "com.apple.keylayout.Dvorak-Left"
    "com.apple.keylayout.Dvorak-Right"
    "com.apple.keylayout.DVORAK-QWERTYCMD"
    # European
    "com.apple.keylayout.German"
    "com.apple.keylayout.French"
    "com.apple.keylayout.Spanish"
    "com.apple.keylayout.Italian"
    "com.apple.keylayout.Portuguese"
    "com.apple.keylayout.Polish"
    "com.apple.keylayout.Greek"
    "com.apple.keylayout.Turkish"
    "com.apple.keylayout.Swiss"
    "com.apple.keylayout.Dutch"
    "com.apple.keylayout.Swedish"
    "com.apple.keylayout.Norwegian"
    "com.apple.keylayout.Danish"
    "com.apple.keylayout.Finnish"
    "com.apple.keylayout.Czech"
    "com.apple.keylayout.Hungarian"
    "com.apple.keylayout.Romanian"
    # Cyrillic
    "com.apple.keylayout.Russian"
    "com.apple.keylayout.Ukrainian"
    # Asian
    "com.apple.keylayout.Vietnamese"
    "com.apple.keylayout.Thai"
    # Middle Eastern
    "com.apple.keylayout.Arabic"
    "com.apple.keylayout.Hebrew"
    "com.apple.keylayout.Persian"
    # Input methods (Asian)
    "com.apple.inputmethod.SCIM.ITABC"
    "com.apple.inputmethod.TCIM.Pinyin"
    "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"
    "com.apple.inputmethod.Korean.2SetKorean"
)

create_swift_helper() {
    cat > "$SWIFT_HELPER" << 'SWIFT_EOF'
#!/usr/bin/swift
import Foundation
import Carbon

func getInputSourceID(_ inputSource: TISInputSource) -> String? {
    guard let ptr = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID) else { return nil }
    return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
}

func getLocalizedName(_ inputSource: TISInputSource) -> String? {
    guard let ptr = TISGetInputSourceProperty(inputSource, kTISPropertyLocalizedName) else { return nil }
    return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
}

func isEnabled(_ inputSource: TISInputSource) -> Bool {
    guard let ptr = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceIsEnabled) else { return false }
    return Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue() == kCFBooleanTrue
}

func getAllInputSources() -> [TISInputSource] {
    guard let sourceList = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else {
        return []
    }
    return sourceList
}

func getEnabledInputSources() -> [TISInputSource] {
    guard let sourceList = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
        return []
    }
    return sourceList
}

func findInputSource(byID sourceID: String) -> TISInputSource? {
    let properties = [kTISPropertyInputSourceID as String: sourceID] as CFDictionary
    guard let sourceList = TISCreateInputSourceList(properties, true)?.takeRetainedValue() as? [TISInputSource],
          let source = sourceList.first else {
        return nil
    }
    return source
}

func enableInputSource(_ sourceID: String) -> Bool {
    guard let source = findInputSource(byID: sourceID) else {
        fputs("Input source not found: \(sourceID)\n", stderr)
        return false
    }
    let status = TISEnableInputSource(source)
    if status != noErr {
        fputs("Failed to enable \(sourceID): error \(status)\n", stderr)
        return false
    }
    return true
}

func disableInputSource(_ sourceID: String) -> Bool {
    guard let source = findInputSource(byID: sourceID) else {
        fputs("Input source not found: \(sourceID)\n", stderr)
        return false
    }
    let status = TISDisableInputSource(source)
    if status != noErr {
        fputs("Failed to disable \(sourceID): error \(status)\n", stderr)
        return false
    }
    return true
}

func listEnabled() {
    let sources = getEnabledInputSources()
    for source in sources {
        if let sourceID = getInputSourceID(source) {
            print(sourceID)
        }
    }
}

func listAll() {
    let sources = getAllInputSources()
    for source in sources {
        if let sourceID = getInputSourceID(source),
           let name = getLocalizedName(source) {
            let enabledStr = isEnabled(source) ? "[enabled]" : ""
            print("\(sourceID) (\(name)) \(enabledStr)")
        }
    }
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("""
    Usage: \(args[0]) <command> [args...]
    
    Commands:
      list-enabled          List enabled input sources (IDs only)
      list-all              List all available input sources
      enable <source_id>    Enable an input source
      disable <source_id>   Disable an input source
      enable-many <ids...>  Enable multiple input sources
      disable-many <ids...> Disable multiple input sources
    
    """, stderr)
    exit(1)
}

let command = args[1]

switch command {
case "list-enabled":
    listEnabled()
case "list-all":
    listAll()
case "enable":
    guard args.count >= 3 else {
        fputs("Usage: enable <source_id>\n", stderr)
        exit(1)
    }
    if enableInputSource(args[2]) {
        print("Enabled: \(args[2])")
    } else {
        exit(1)
    }
case "disable":
    guard args.count >= 3 else {
        fputs("Usage: disable <source_id>\n", stderr)
        exit(1)
    }
    if disableInputSource(args[2]) {
        print("Disabled: \(args[2])")
    } else {
        exit(1)
    }
case "enable-many":
    guard args.count >= 3 else {
        fputs("Usage: enable-many <source_id> [source_id...]\n", stderr)
        exit(1)
    }
    var success = 0
    var failed = 0
    for i in 2..<args.count {
        if enableInputSource(args[i]) {
            success += 1
        } else {
            failed += 1
        }
    }
    print("Enabled: \(success), Failed: \(failed)")
case "disable-many":
    guard args.count >= 3 else {
        fputs("Usage: disable-many <source_id> [source_id...]\n", stderr)
        exit(1)
    }
    var success = 0
    var failed = 0
    for i in 2..<args.count {
        if disableInputSource(args[i]) {
            success += 1
        } else {
            failed += 1
        }
    }
    print("Disabled: \(success), Failed: \(failed)")
default:
    fputs("Unknown command: \(command)\n", stderr)
    exit(1)
}
SWIFT_EOF
    chmod +x "$SWIFT_HELPER"
}

run_swift_helper() {
    swift "$SWIFT_HELPER" "$@"
}

list_layouts() {
    echo "Currently enabled keyboard layouts:"
    create_swift_helper
    run_swift_helper list-enabled
}

list_all_layouts() {
    echo "All available keyboard layouts:"
    create_swift_helper
    run_swift_helper list-all
}

backup_layouts() {
    echo "Backing up current keyboard layouts to $BACKUP_FILE..."
    create_swift_helper
    run_swift_helper list-enabled > "$BACKUP_FILE"
    if [ $? -eq 0 ]; then
        echo "Backup saved successfully ($(wc -l < "$BACKUP_FILE" | tr -d ' ') layouts)."
    else
        echo "Failed to backup layouts."
        exit 1
    fi
}

setup_layouts() {
    if [ -f "$BACKUP_FILE" ]; then
        echo "Backup already exists at $BACKUP_FILE"
        echo "Run 'restore' first if you want to create a new backup."
        read -p "Continue anyway and overwrite backup? (y/N): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            exit 0
        fi
    fi
    
    backup_layouts
    
    echo ""
    echo "Enabling test keyboard layouts using TIS API..."
    echo "(Changes take effect immediately - no logout required)"
    echo ""
    
    create_swift_helper
    
    local enabled=0
    local failed=0
    
    for layout in "${TEST_LAYOUTS[@]}"; do
        echo -n "  Enabling: $layout ... "
        if run_swift_helper enable "$layout" 2>/dev/null | grep -q "Enabled"; then
            echo "OK"
            ((enabled++))
        else
            echo "FAILED (may not be available on this system)"
            ((failed++))
        fi
    done
    
    echo ""
    echo "Setup complete!"
    echo "  Enabled: $enabled layouts"
    echo "  Failed: $failed layouts"
}

restore_layouts() {
    if [ ! -f "$BACKUP_FILE" ]; then
        echo "No backup file found at $BACKUP_FILE"
        echo "Nothing to restore."
        exit 1
    fi
    
    echo "Restoring keyboard layouts from backup using TIS API..."
    echo "(Changes take effect immediately - no logout required)"
    echo ""
    
    create_swift_helper
    
    # Get currently enabled layouts
    echo "Getting current layouts..."
    local current_layouts
    current_layouts=$(run_swift_helper list-enabled)
    
    # Read backup file
    local backup_layouts
    backup_layouts=$(cat "$BACKUP_FILE")
    
    # Disable layouts that are not in backup
    echo "Disabling layouts that were added during testing..."
    local disabled=0
    while IFS= read -r layout; do
        if [ -n "$layout" ] && ! echo "$backup_layouts" | grep -q "^${layout}$"; then
            echo -n "  Disabling: $layout ... "
            if run_swift_helper disable "$layout" 2>/dev/null | grep -q "Disabled"; then
                echo "OK"
                ((disabled++))
            else
                echo "FAILED"
            fi
        fi
    done <<< "$current_layouts"
    
    # Enable layouts from backup that might have been disabled
    echo ""
    echo "Re-enabling original layouts..."
    local enabled=0
    while IFS= read -r layout; do
        if [ -n "$layout" ]; then
            # Check if already enabled
            if ! echo "$current_layouts" | grep -q "^${layout}$"; then
                echo -n "  Enabling: $layout ... "
                if run_swift_helper enable "$layout" 2>/dev/null | grep -q "Enabled"; then
                    echo "OK"
                    ((enabled++))
                else
                    echo "FAILED"
                fi
            fi
        fi
    done <<< "$backup_layouts"
    
    rm "$BACKUP_FILE"
    echo ""
    echo "Restore complete!"
    echo "  Disabled: $disabled layouts"
    echo "  Re-enabled: $enabled layouts"
    echo "  Backup file removed."
}

show_help() {
    echo "Keyboard Layout Manager for Testing"
    echo ""
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  setup    - Backup current layouts and install test layouts"
    echo "  restore  - Restore original layouts from backup"
    echo "  list     - List currently enabled keyboard layouts"
    echo "  list-all - List all available keyboard layouts"
    echo "  help     - Show this help message"
    echo ""
    echo "This script uses macOS TIS (Text Input Source) API to manage"
    echo "keyboard layouts. Changes take effect IMMEDIATELY without"
    echo "requiring logout/login."
    echo ""
    echo "Test layouts that will be installed:"
    echo "  - US, ABC, British, US International, Colemak"
    echo "  - Dvorak, Dvorak-Left, Dvorak-Right, Dvorak-QWERTY"
    echo "  - German, French, Spanish, Italian, Portuguese, Polish"
    echo "  - Greek, Turkish, Swiss, Dutch, Swedish, Norwegian"
    echo "  - Danish, Finnish, Czech, Hungarian, Romanian"
    echo "  - Russian, Ukrainian"
    echo "  - Vietnamese, Thai"
    echo "  - Arabic, Hebrew, Persian"
    echo "  - Chinese (Pinyin), Japanese, Korean"
}

# Main
case "$1" in
    setup)
        setup_layouts
        ;;
    restore)
        restore_layouts
        ;;
    list)
        list_layouts
        ;;
    list-all)
        list_all_layouts
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Unknown command: $1"
        echo ""
        show_help
        exit 1
        ;;
esac
