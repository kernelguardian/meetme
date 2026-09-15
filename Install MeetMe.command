#!/bin/bash
# Double-click this file in Finder to install MeetMe. It is a thin wrapper around
# install/install.sh so the whole setup is one thing you can open.
cd "$(dirname "$0")" || exit 1

./install/install.sh "$@"
status=$?

echo
if [ "$status" -eq 0 ]; then
  echo "MeetMe: setup finished."
else
  echo "MeetMe: setup failed (exit $status). The messages above say why."
fi
read -n 1 -s -r -p "Press any key to close this window…"
echo
exit "$status"
