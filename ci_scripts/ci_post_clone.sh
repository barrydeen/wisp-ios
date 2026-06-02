#!/bin/sh

# Xcode Cloud is headless and cannot show the "Trust & Enable" prompt for
# Swift Package build-tool plugins (e.g. SharedSourcesPlugin from
# swift-secp256k1). Skip plugin + macro fingerprint validation so the
# archive step can run them non-interactively.
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
