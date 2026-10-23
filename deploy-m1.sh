#!/bin/bash
# Плеер на M1 (ssh-хост m1): сборка, копирование в /Applications, перезапуск, хвост лога
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
ssh m1 'pkill -x LiveVideoSync || true; sleep 2'
rsync -a --delete build/LiveVideoSync.app m1:/Applications/
ssh m1 '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/LiveVideoSync.app; open /Applications/LiveVideoSync.app'
sleep 4
ssh m1 'tail -n 20 ~/Library/Logs/LiveVideoSync/lvs.log'
