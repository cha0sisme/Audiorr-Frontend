#!/bin/sh
set -euo pipefail

cd "$CI_PRIMARY_REPOSITORY_PATH/ios/App"
agvtool new-version -all "$CI_BUILD_NUMBER"

echo "CURRENT_PROJECT_VERSION set to $CI_BUILD_NUMBER"
