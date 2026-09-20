# List available recipes
default:
    @just --list

# Build, sign, and install ClaudeUsage.app
build *args:
    ./Scripts/build.sh {{args}}

# Build, sign, and package a Developer ID release [ --notary-profile ]
release *args:
    ./Scripts/release.sh {{args}}

# Re-sign a build product with the stable certificate-backed identity
sign target=".build/debug/ClaudeUsage":
    ./Scripts/dev-sign.sh "{{target}}"

# Regenerate docs/screenshots [ --check ]
screenshot *args:
    ./Scripts/screenshots.sh {{args}}


