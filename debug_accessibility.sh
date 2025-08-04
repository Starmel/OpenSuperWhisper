#!/bin/bash

# Debug Accessibility Permissions Script

echo "🔐 Debug Accessibility Permissions"
echo "=================================="
echo ""

APP_NAME="OpenSuperWhisper"
BUNDLE_ID="com.opensuperwhisper.OpenSuperWhisper"

# Function to check if app is running
check_app_running() {
    if pgrep -x "$APP_NAME" > /dev/null; then
        echo "✅ $APP_NAME is running (PID: $(pgrep -x "$APP_NAME"))"
        return 0
    else
        echo "❌ $APP_NAME is not running"
        return 1
    fi
}

# Function to check accessibility permissions
check_accessibility_permissions() {
    echo "🔍 Checking accessibility permissions..."
    
    # Check if the app appears in accessibility list
    if /usr/bin/sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db "SELECT client FROM access WHERE service='kTCCServiceAccessibility' AND client LIKE '%$BUNDLE_ID%';" 2>/dev/null | grep -q "$BUNDLE_ID"; then
        echo "✅ App found in accessibility database"
        
        # Check if it's enabled
        local allowed=$(/usr/bin/sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db "SELECT allowed FROM access WHERE service='kTCCServiceAccessibility' AND client LIKE '%$BUNDLE_ID%';" 2>/dev/null)
        if [ "$allowed" = "1" ]; then
            echo "✅ Accessibility permission is GRANTED"
        else
            echo "❌ Accessibility permission is DENIED"
        fi
    else
        echo "❌ App not found in accessibility database"
        echo "   This usually means the app hasn't requested permission yet"
    fi
}

# Function to reset accessibility permissions
reset_accessibility_permissions() {
    echo "🔄 Resetting accessibility permissions..."
    
    # Kill the app first
    if pgrep -x "$APP_NAME" > /dev/null; then
        echo "Stopping $APP_NAME..."
        killall "$APP_NAME" 2>/dev/null
        sleep 2
    fi
    
    # Reset TCC database entry
    echo "Removing TCC database entry..."
    sudo /usr/bin/sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db "DELETE FROM access WHERE service='kTCCServiceAccessibility' AND client LIKE '%$BUNDLE_ID%';" 2>/dev/null
    
    echo "✅ Accessibility permissions reset"
    echo "⚠️  You'll need to grant permission again when you launch the app"
}

# Function to force refresh permissions
refresh_permissions() {
    echo "🔄 Refreshing accessibility permissions..."
    
    # Method 1: Reset and restart accessibility daemon
    sudo launchctl stop com.apple.accessibility.heard
    sudo launchctl start com.apple.accessibility.heard
    
    # Method 2: Refresh TCC daemon
    sudo launchctl stop com.apple.tccd
    sudo launchctl start com.apple.tccd
    
    sleep 2
    echo "✅ Accessibility services refreshed"
}

# Function to check app signature and notarization
check_app_signature() {
    local app_path="/Applications/$APP_NAME.app"
    
    echo "🔍 Checking app signature and notarization..."
    
    if [ ! -d "$app_path" ]; then
        echo "❌ App not found at $app_path"
        return 1
    fi
    
    # Check code signature
    echo "Checking code signature..."
    if codesign -v "$app_path" 2>/dev/null; then
        echo "✅ App is properly code signed"
    else
        echo "⚠️  App signature issues detected"
        echo "   This can cause accessibility permission problems"
    fi
    
    # Check notarization
    echo "Checking notarization..."
    if spctl -a -v "$app_path" 2>&1 | grep -q "accepted"; then
        echo "✅ App is properly notarized"
    else
        echo "⚠️  App notarization issues detected"
        echo "   This can cause security restrictions"
    fi
}

# Function to show manual steps
show_manual_steps() {
    echo "📋 Manual Steps to Fix Accessibility Permissions"
    echo "=============================================="
    echo ""
    echo "1. Open System Preferences/Settings"
    echo "2. Go to Security & Privacy → Privacy → Accessibility"
    echo "3. Look for '$APP_NAME' in the list"
    echo "4. If present but unchecked: Check the box"
    echo "5. If not present:"
    echo "   a. Click the '+' button"
    echo "   b. Navigate to /Applications/$APP_NAME.app"
    echo "   c. Select it and click 'Open'"
    echo "   d. Check the box next to it"
    echo "6. If still not working:"
    echo "   a. Uncheck the box"
    echo "   b. Remove the app from the list (select and click '-')"
    echo "   c. Restart the app to trigger permission request again"
    echo ""
    echo "Alternative command to open preferences:"
    echo "open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'"
}

# Function to open system preferences
open_accessibility_prefs() {
    echo "🔧 Opening Accessibility preferences..."
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
}

# Function to show detailed diagnostics
show_diagnostics() {
    echo "🔍 Detailed Diagnostics"
    echo "======================"
    echo ""
    
    echo "System Information:"
    echo "- macOS Version: $(sw_vers -productVersion)"
    echo "- Build Version: $(sw_vers -buildVersion)"
    echo ""
    
    echo "App Information:"
    local app_path="/Applications/$APP_NAME.app"
    if [ -d "$app_path" ]; then
        echo "- App Path: $app_path"
        echo "- Bundle ID: $(defaults read "$app_path/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "Not found")"
        echo "- App Version: $(defaults read "$app_path/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "Not found")"
    else
        echo "❌ App not found at expected location"
    fi
    echo ""
    
    echo "Current TCC Database Entries:"
    /usr/bin/sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db "SELECT service, client, allowed, prompt_count FROM access WHERE client LIKE '%opensuperwhisper%' OR client LIKE '%OpenSuperWhisper%';" 2>/dev/null || echo "No entries found"
}

# Function to show menu
show_menu() {
    echo ""
    echo "Available actions:"
    echo "1) Check app status"
    echo "2) Check accessibility permissions"
    echo "3) Reset accessibility permissions (requires sudo)"
    echo "4) Refresh accessibility services (requires sudo)"
    echo "5) Check app signature and notarization"
    echo "6) Show manual fix steps"
    echo "7) Open Accessibility preferences"
    echo "8) Show detailed diagnostics"
    echo "9) Launch app"
    echo "10) Exit"
    echo ""
    read -p "Choose an action (1-10): " choice
}

# Main loop
while true; do
    show_menu
    
    case $choice in
        1)
            check_app_running
            ;;
        2)
            check_accessibility_permissions
            ;;
        3)
            if [ "$EUID" -ne 0 ]; then
                echo "⚠️  This action requires sudo privileges"
                echo "Run: sudo $0"
            else
                reset_accessibility_permissions
            fi
            ;;
        4)
            if [ "$EUID" -ne 0 ]; then
                echo "⚠️  This action requires sudo privileges"
                echo "Run: sudo $0"
            else
                refresh_permissions
            fi
            ;;
        5)
            check_app_signature
            ;;
        6)
            show_manual_steps
            ;;
        7)
            open_accessibility_prefs
            ;;
        8)
            show_diagnostics
            ;;
        9)
            echo "🚀 Launching $APP_NAME..."
            open "/Applications/$APP_NAME.app"
            sleep 2
            check_app_running
            ;;
        10)
            echo "👋 Goodbye!"
            exit 0
            ;;
        *)
            echo "❌ Invalid choice. Please choose 1-10."
            ;;
    esac
    
    echo ""
    read -p "Press Enter to continue..."
done