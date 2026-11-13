#!/bin/bash
set -e

# Configuration
NEW_VERSION="${1:-0.0.4}"
CODE_SIGN_IDENTITY="${2}"
GITHUB_TOKEN="${3}"

if [[ -z "$CODE_SIGN_IDENTITY" ]]; then
    echo "❌ Error: Code signing identity is required"
    echo "Usage: $0 <version> <code_sign_identity> [github_token]"
    echo "Example: $0 0.0.4 \"Developer ID Application: Your Name (TEAM_ID)\" ghp_xxxxx"
    exit 1
fi

if [[ -z "$GITHUB_TOKEN" ]]; then
    echo ""
    echo "⚠️  GitHub token not found in environment or arguments"
    echo ""
    read -p "Enter GitHub token (or press Enter to skip GitHub release): " INPUT_TOKEN
    if [[ -n "$INPUT_TOKEN" ]]; then
        GITHUB_TOKEN="$INPUT_TOKEN"
        echo "✅ GitHub token provided"
    else
        echo ""
        echo "⚠️  WARNING: Proceeding without GitHub token"
        echo "   - Git tag will be created and pushed"
        echo "   - GitHub release will NOT be created automatically"
        echo "   - The .pkg will NOT be uploaded to GitHub"
        echo ""
        read -p "Continue without GitHub release? (y/N): " CONTINUE
        if [[ "$CONTINUE" != "y" && "$CONTINUE" != "Y" ]]; then
            echo "❌ Aborted by user"
            exit 1
        fi
    fi
else
    echo "✅ Using GitHub token from environment variable"
fi

echo ""
echo "🚀 Making release for OpenSuperWhisper v${NEW_VERSION}"
echo "   Code signing identity: ${CODE_SIGN_IDENTITY}"
if [[ -n "$GITHUB_TOKEN" ]]; then
    echo "   GitHub release: ✅ Enabled"
else
    echo "   GitHub release: ❌ Disabled (no token)"
fi
echo ""

# # Update version in Xcode project
echo "📝 Updating version to ${NEW_VERSION} in Xcode project..."

# Update MARKETING_VERSION in project.pbxproj
sed -i '' "s/MARKETING_VERSION = [^;]*/MARKETING_VERSION = ${NEW_VERSION}/g" OpenSuperWhisper.xcodeproj/project.pbxproj

# Get current PROJECT_VERSION and increment by 1
CURRENT_PROJECT_VERSION=$(grep -o 'CURRENT_PROJECT_VERSION = [0-9]*' OpenSuperWhisper.xcodeproj/project.pbxproj | head -1 | grep -o '[0-9]*')
NEW_PROJECT_VERSION=$((CURRENT_PROJECT_VERSION + 1))
sed -i '' "s/CURRENT_PROJECT_VERSION = [^;]*/CURRENT_PROJECT_VERSION = ${NEW_PROJECT_VERSION}/g" OpenSuperWhisper.xcodeproj/project.pbxproj

echo "✅ Updated MARKETING_VERSION to ${NEW_VERSION} and CURRENT_PROJECT_VERSION to ${NEW_PROJECT_VERSION} (was ${CURRENT_PROJECT_VERSION})"

# Clean previous builds
echo "🧹 Cleaning previous builds..."
rm -rf build
rm -f OpenSuperWhisper.dmg
rm -f OpenSuperWhisper.dmg.sha256
rm -f OpenSuperWhisper.app.dSYM.zip

# Use the existing notarize_app.sh script to build, sign, and notarize
echo "🔨 Building, signing and notarizing with notarize_app.sh..."
if [[ ! -f "./notarize_app.sh" ]]; then
    echo "❌ notarize_app.sh not found!"
    exit 1
fi

chmod +x ./notarize_app.sh
./notarize_app.sh "${CODE_SIGN_IDENTITY}"

if [[ $? -ne 0 ]]; then
    echo "❌ Build/notarization failed!"
    exit 1
fi

echo "✅ Build and notarization successful!"

# The package is the artifact users install: it carries the app AND the
# uninstall command, and it registers the receipt the uninstaller forgets.
# notarize_app.sh builds it next to the checkout.
APP_PATH="./build/Build/Products/Release/OpenSuperWhisper.app"
BUILT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "")
PKG_PATH="./OpenSuperWhisper-${BUILT_VERSION}.pkg"

if [[ ! -f "$PKG_PATH" ]]; then
    echo "❌ Package not found at $PKG_PATH"
    echo "   notarize_app.sh emits it for the version it built (${BUILT_VERSION:-unknown})."
    exit 1
fi

# The cask DMG is optional: swifty-dmg may not be installed, and the package
# alone is a complete install.
DMG_PATH="./OpenSuperWhisper.dmg"
if [[ ! -f "$DMG_PATH" ]]; then
    echo "ℹ️  No DMG at $DMG_PATH (swifty-dmg not installed): releasing the package only."
    DMG_PATH=""
fi

# Find and prepare dSYM
DSYM_PATH="./build/Build/Products/Release/OpenSuperWhisper.app.dSYM"
DSYM_ZIP_PATH="./OpenSuperWhisper.app.dSYM.zip"

if [[ -d "$DSYM_PATH" ]]; then
    echo "📦 Creating dSYM zip..."
    cd $(dirname "$DSYM_PATH")
    zip -r "$(basename "$DSYM_ZIP_PATH")" "$(basename "$DSYM_PATH")" > /dev/null
    mv "$(basename "$DSYM_ZIP_PATH")" "$DSYM_ZIP_PATH"
    cd - > /dev/null
    echo "✅ dSYM zip created: $DSYM_ZIP_PATH"
else
    echo "⚠️ dSYM not found at $DSYM_PATH - skipping dSYM upload"
    DSYM_ZIP_PATH=""
fi

# # Generate SHA256
echo "🔍 Generating SHA256..."
shasum -a 256 "$PKG_PATH" > "${PKG_PATH}.sha256"
SHA256=$(cat "${PKG_PATH}.sha256" | cut -d' ' -f1)
echo "PKG SHA256: $SHA256"
if [[ -n "$DMG_PATH" ]]; then
    shasum -a 256 "$DMG_PATH" > "${DMG_PATH}.sha256"
    echo "DMG SHA256: $(cat "${DMG_PATH}.sha256" | cut -d' ' -f1)"
fi

# # Commit version changes
echo "📝 Committing version changes..."
git add OpenSuperWhisper.xcodeproj/project.pbxproj
git commit -m "Bump version to ${NEW_VERSION}" || echo "No changes to commit"

# Create git tag
echo "🏷️ Creating git tag..."
git tag -a "${NEW_VERSION}" -m "Release ${NEW_VERSION}"

# Push tag to origin
echo "📤 Pushing tag to origin..."
git push origin "${NEW_VERSION}"

if [[ $? -ne 0 ]]; then
    echo "❌ Failed to push tag!"
    exit 1
fi

# Create GitHub release and upload the package if a token is provided
if [[ -n "$GITHUB_TOKEN" ]]; then
    echo "🚀 Creating GitHub release..."
    
    # Create release
    RELEASE_RESPONSE=$(curl -s -L -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        https://api.github.com/repos/Starmel/OpenSuperWhisper/releases \
        -d '{
            "tag_name": "'${NEW_VERSION}'",
            "target_commitish": "master",
            "name": "Release '${NEW_VERSION}'",
            "body": "## OpenSuperWhisper '${NEW_VERSION}'\n\nReal-time audio transcription for macOS using Whisper.\n\n## Installation\n\n### Homebrew (Recommended)\n```bash\nbrew update\nbrew install opensuperwhisper\n```\n\n### Manual Installation\n1. Download the `OpenSuperWhisper-${NEW_VERSION}.pkg` file below\n2. Open the package and follow the installer\n3. Launch the app and grant necessary permissions\n\n## Requirements\n- macOS 14.0 (Sonoma) or later\n- Apple Silicon (ARM64) Mac",
            "draft": false,
            "prerelease": false,
            "generate_release_notes": false
        }')
    
    # Extract release ID from response
    RELEASE_ID=$(echo "$RELEASE_RESPONSE" | grep -o '"id": [0-9]*' | head -1 | grep -o '[0-9]*')
    
    if [[ -z "$RELEASE_ID" ]]; then
        echo "❌ Failed to create GitHub release or extract release ID"
        echo "Response: $RELEASE_RESPONSE"
        exit 1
    fi
    
    echo "✅ GitHub release created (ID: $RELEASE_ID)!"

    # Upload one release asset, exiting if GitHub rejects it. The package is
    # the artifact every install path uses; the DMG only feeds the cask.
    upload_asset() { # path, asset name, content type
        local path="$1" name="$2" content_type="$3"
        echo "📤 Uploading ${name}..."
        local response
        response=$(curl -s -L -X POST \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer ${GITHUB_TOKEN}" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            -H "Content-Type: ${content_type}" \
            "https://uploads.github.com/repos/Starmel/OpenSuperWhisper/releases/${RELEASE_ID}/assets?name=${name}" \
            --data-binary @"${path}")

        if [[ $(echo "$response" | grep -c '"state":"uploaded"') -gt 0 ]] || [[ $(echo "$response" | grep -c '"state": "uploaded"') -gt 0 ]]; then
            echo "✅ ${name} uploaded successfully!"
            echo "📥 Download URL: $(echo "$response" | grep -o '"browser_download_url":"[^"]*' | cut -d'"' -f4)"
        elif [[ $(echo "$response" | grep -c '"message"') -gt 0 ]]; then
            echo "❌ Failed to upload ${name}"
            echo "Error: $(echo "$response" | grep -o '"message":"[^"]*' | cut -d'"' -f4)"
            exit 1
        else
            echo "⚠️ Upload response unclear, but no error detected"
            echo "Response: $response"
        fi
    }

    upload_asset "$PKG_PATH" "$(basename "$PKG_PATH")" "application/octet-stream"
    if [[ -n "$DMG_PATH" ]]; then
        upload_asset "$DMG_PATH" "OpenSuperWhisper.dmg" "application/octet-stream"
    fi

    # Upload dSYM if available
    if [[ -n "$DSYM_ZIP_PATH" && -f "$DSYM_ZIP_PATH" ]]; then
        echo "📤 Uploading dSYM..."
        
        DSYM_UPLOAD_RESPONSE=$(curl -s -L -X POST \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer ${GITHUB_TOKEN}" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            -H "Content-Type: application/zip" \
            "https://uploads.github.com/repos/Starmel/OpenSuperWhisper/releases/${RELEASE_ID}/assets?name=OpenSuperWhisper.app.dSYM.zip" \
            --data-binary @"${DSYM_ZIP_PATH}")
        
        # Check dSYM upload
        if [[ $(echo "$DSYM_UPLOAD_RESPONSE" | grep -c '"state":"uploaded"') -gt 0 ]] || [[ $(echo "$DSYM_UPLOAD_RESPONSE" | grep -c '"state": "uploaded"') -gt 0 ]]; then
            echo "✅ dSYM uploaded successfully!"
            # Extract download URL
            DSYM_DOWNLOAD_URL=$(echo "$DSYM_UPLOAD_RESPONSE" | grep -o '"browser_download_url":"[^"]*' | cut -d'"' -f4)
            echo "📥 dSYM Download URL: $DSYM_DOWNLOAD_URL"
        elif [[ $(echo "$DSYM_UPLOAD_RESPONSE" | grep -c '"message"') -gt 0 ]]; then
            echo "⚠️ Failed to upload dSYM (non-critical)"
            echo "Error: $(echo "$DSYM_UPLOAD_RESPONSE" | grep -o '"message":"[^"]*' | cut -d'"' -f4)"
        else
            echo "⚠️ dSYM upload response unclear"
        fi
    fi
    
    echo "✅ Release assets uploaded successfully!"
    echo "🎉 GitHub release is complete!"
    echo "🔗 Release URL: https://github.com/Starmel/OpenSuperWhisper/releases/tag/${NEW_VERSION}"
else
    echo "⚠️ Skipping GitHub release creation (no token provided)"
    echo "📋 Manual steps needed:"
    echo "1. Create GitHub release at:"
    echo "   https://github.com/Starmel/OpenSuperWhisper/releases/new?tag=${NEW_VERSION}"
    echo "2. Upload the package: ${PKG_PATH}"
fi

echo ""
echo "🎉 Release ${NEW_VERSION} is ready!"
echo ""
echo "📁 Files created:"
echo "   - ${PKG_PATH}"
echo "   - ${PKG_PATH}.sha256"
if [[ -n "$DMG_PATH" ]]; then
    echo "   - ${DMG_PATH}"
    echo "   - ${DMG_PATH}.sha256"
fi
if [[ -f "$DSYM_ZIP_PATH" ]]; then
    echo "   - OpenSuperWhisper.app.dSYM.zip"
fi
echo ""
echo "🍺 Homebrew cask update:"
echo "-----"
cat << EOF
cask "opensuperwhisper" do
  version "${NEW_VERSION}"
  sha256 "${SHA256}"

  url "https://github.com/starmel/OpenSuperWhisper/releases/download/#{version}/OpenSuperWhisper-#{version}.pkg"
  name "OpenSuperWhisper"
  desc "Whisper dictation/transcription app"
  homepage "https://github.com/starmel/OpenSuperWhisper"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  pkg "OpenSuperWhisper-#{version}.pkg"

  # The package's own uninstaller (inside the app, and at
  # /Applications/Uninstall OpenSuperWhisper.command) is the primary operation;
  # this is the Homebrew-side backstop for a cask uninstall. Keep it in step
  # with packaging/uninstall.sh, which owns the list: the app, the uninstall
  # command, the installed and downloaded models, the caches and the receipt —
  # and deliberately not the recordings, the transcriptions or the settings.
  # `zap` below is the full wipe and is the only thing here that takes them. It
  # never touches ~/models or another app.
  uninstall quit:    "ru.starmel.OpenSuperWhisper",
            pkgutil: "ru.starmel.OpenSuperWhisper"

  zap trash: [
    "~/Library/Application Scripts/ru.starmel.OpenSuperWhisper",
    "~/Library/Application Support/ru.starmel.OpenSuperWhisper",
    "~/Library/Application Support/CrashReporter/OpenSuperWhisper_*.plist",
    "~/Library/Caches/ru.starmel.OpenSuperWhisper",
    "~/Library/HTTPStorages/ru.starmel.OpenSuperWhisper",
    "~/Library/Logs/DiagnosticReports/OpenSuperWhisper-*.ips",
    "~/Library/Preferences/ru.starmel.OpenSuperWhisper.plist",
    "~/Library/Saved Application State/ru.starmel.OpenSuperWhisper.savedState",
  ]
end
EOF
echo "-----" 