#!/bin/bash

# Debug Mistral STT Integration Script

echo "🔍 Debug Mistral STT Integration"
echo "================================="
echo ""

# Function to check if app is running
check_app_running() {
    if pgrep -x "OpenSuperWhisper" > /dev/null; then
        echo "✅ OpenSuperWhisper is running"
        return 0
    else
        echo "❌ OpenSuperWhisper is not running"
        return 1
    fi
}

# Function to enable debug mode
enable_debug_mode() {
    echo "🔧 Enabling debug mode..."
    defaults write com.opensuperwhisper.OpenSuperWhisper debugMode -bool true
    echo "✅ Debug mode enabled"
}

# Function to check current settings
check_settings() {
    echo "📋 Current STT Settings:"
    echo "- Primary Provider: $(defaults read com.opensuperwhisper.OpenSuperWhisper primarySTTProvider 2>/dev/null || echo 'whisper_local')"
    echo "- Fallback Enabled: $(defaults read com.opensuperwhisper.OpenSuperWhisper enableSTTFallback 2>/dev/null || echo 'true')"
    echo "- Debug Mode: $(defaults read com.opensuperwhisper.OpenSuperWhisper debugMode 2>/dev/null || echo 'false')"
}

# Function to view logs
view_logs() {
    echo "📊 Viewing recent logs..."
    echo "Press Ctrl+C to stop log viewing"
    sleep 1
    
    # View system logs for our app
    log stream --predicate 'subsystem == "com.opensuperwhisper.app"' --info --debug
}

# Function to set Mistral as primary
set_mistral_primary() {
    echo "🔄 Setting Mistral as primary STT provider..."
    defaults write com.opensuperwhisper.OpenSuperWhisper primarySTTProvider -string "mistral_voxtral"
    echo "✅ Mistral set as primary provider"
}

# Function to reset to Whisper local
reset_to_whisper() {
    echo "🔄 Resetting to Whisper Local..."
    defaults write com.opensuperwhisper.OpenSuperWhisper primarySTTProvider -string "whisper_local"
    echo "✅ Reset to Whisper Local"
}

# Function to show menu
show_menu() {
    echo ""
    echo "Available actions:"
    echo "1) Check app status"
    echo "2) Enable debug mode"
    echo "3) Check current settings"
    echo "4) Set Mistral as primary provider"
    echo "5) Reset to Whisper Local"
    echo "6) View live logs"
    echo "7) Launch app"
    echo "8) Exit"
    echo ""
    read -p "Choose an action (1-8): " choice
}

# Main loop
while true; do
    show_menu
    
    case $choice in
        1)
            check_app_running
            ;;
        2)
            enable_debug_mode
            ;;
        3)
            check_settings
            ;;
        4)
            set_mistral_primary
            echo "⚠️  You'll need to restart the app for changes to take effect"
            ;;
        5)
            reset_to_whisper
            echo "⚠️  You'll need to restart the app for changes to take effect"
            ;;
        6)
            view_logs
            ;;
        7)
            echo "🚀 Launching OpenSuperWhisper..."
            open "/Applications/OpenSuperWhisper.app"
            sleep 2
            check_app_running
            ;;
        8)
            echo "👋 Goodbye!"
            exit 0
            ;;
        *)
            echo "❌ Invalid choice. Please choose 1-8."
            ;;
    esac
    
    echo ""
    read -p "Press Enter to continue..."
done