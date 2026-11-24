#!/bin/bash
set -eu
sudo xcode-select -s /Applications/Xcode_26.app/Contents/Developer || sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -version
