#!/bin/bash
df -h /
sudo rm -rf /Library/Developer/CoreSimulator/Profiles/Runtimes || true
rm -rf ~/Library/Developer/CoreSimulator/Caches || true
sudo rm -rf /Applications/Xcode_15*.app /Applications/Xcode_16.0.app /Applications/Xcode_16.1.app || true
df -h /
