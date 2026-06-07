#!/bin/sh

# Xcode Cloud is headless and cannot show the "Trust & Enable" prompt for
# Swift Package build-tool plugins (e.g. SharedSourcesPlugin from
# swift-secp256k1). Skip plugin + macro fingerprint validation so the
# archive step can run them non-interactively.
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES

# Materialize gitignored secret resource files from Xcode Cloud environment
# variables (App Store Connect -> workflow -> Environment Variables, marked
# Secret). wisp/ is a synchronized group, so anything written into
# wisp/Resources/ before the build is bundled automatically.
REPO="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
RESOURCES="$REPO/wisp/Resources"

write_secret() {
    # $1 = env var name, $2 = destination file name
    eval "value=\${$1:-}"
    if [ -n "$value" ]; then
        printf '%s' "$value" > "$RESOURCES/$2"
        echo "ci_post_clone: wrote $2"
    else
        echo "ci_post_clone: WARNING: $1 not set, $2 missing from bundle" >&2
    fi
}

write_secret BREEZ_API_KEY breez-api-key.txt
write_secret GIPHY_API_KEY giphy-api-key.txt
write_secret GOOGLE_WEB_CLIENT_ID google-web-client-id.txt
write_secret GOOGLE_IOS_CLIENT_ID google-ios-client-id.txt
