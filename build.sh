#!/bin/bash

# FluidVoice Build Profile Router
# Defaults to the public OSS build, which skips private Fluid Intelligence.
#
# Usage:
#   ./build.sh                    # public OSS build
#   ./build.sh public             # public OSS build
#   ./build.sh fi                 # private FI build

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE="${1:-${BUILD_PROFILE:-public}}"
PRIVATE_FI_BUILD_SCRIPT="${PROJECT_DIR}/build_with_FI_incremental.sh"

case "${PROFILE}" in
    public|oss|incremental|fast)
        echo "Running public FluidVoice build without Fluid Intelligence..."
        cd "${PROJECT_DIR}"
        xcodebuild -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS' build \
            CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=

        # xcodebuild's CLI build does not embed SPM dynamic frameworks
        # (MediaRemoteAdapter), so the bundle crashes at launch with dyld
        # "Library missing". Copy them in and re-sign ad hoc.
        SETTINGS=$(xcodebuild -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS' -showBuildSettings 2>/dev/null)
        PRODUCTS_DIR=$(echo "${SETTINGS}" | awk -F' = ' '/ BUILT_PRODUCTS_DIR =/ {print $2; exit}')
        APP_PATH="${PRODUCTS_DIR}/$(echo "${SETTINGS}" | awk -F' = ' '/ FULL_PRODUCT_NAME =/ {print $2; exit}')"

        if [ -d "${PRODUCTS_DIR}/PackageFrameworks" ]; then
            mkdir -p "${APP_PATH}/Contents/Frameworks"
            for fw in "${PRODUCTS_DIR}/PackageFrameworks"/*.framework; do
                echo "Embedding $(basename "${fw}")"
                rm -rf "${APP_PATH}/Contents/Frameworks/$(basename "${fw}")"
                cp -R "${fw}" "${APP_PATH}/Contents/Frameworks/"
                codesign --force --sign - "${APP_PATH}/Contents/Frameworks/$(basename "${fw}")"
            done
            codesign --force --sign - --entitlements "${PROJECT_DIR}/Fluid.entitlements" "${APP_PATH}"
        fi

        echo "App ready at: ${APP_PATH}"
        ;;
    fi|private|dev|full)
        if [ ! -x "${PRIVATE_FI_BUILD_SCRIPT}" ]; then
            echo "Private Fluid Intelligence build script is missing:"
            echo "  ${PRIVATE_FI_BUILD_SCRIPT}"
            echo "Restore the private FI build setup, then run: sh build_with_FI_incremental.sh"
            exit 1
        fi
        exec "${PRIVATE_FI_BUILD_SCRIPT}"
        ;;
    *)
        echo "Unknown build profile: ${PROFILE}"
        echo "Valid profiles: public/oss/incremental/fast, fi/private/dev/full"
        exit 1
        ;;
esac
