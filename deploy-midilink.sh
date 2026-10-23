#!/bin/bash
# MIDI Link на MacBook (ssh-хост macbook): сборка, копирование, запуск. Аргументы передаются программе.
set -euo pipefail
cd "$(dirname "$0")"
./build-midilink.sh
ssh macbook 'pkill -x MIDILink || true; mkdir -p ~/Applications'
rsync -a --delete build/MIDILink.app macbook:Applications/
ssh macbook '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/MIDILink.app'
ssh macbook "open ~/Applications/MIDILink.app --args $*"
