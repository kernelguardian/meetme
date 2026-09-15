#!/bin/bash
# Double-click this file in Finder to remove MeetMe's helper and its browser
# registrations. Your recordings and the folder you chose are left alone.
cd "$(dirname "$0")" || exit 1

echo "This removes the MeetMe helper and unregisters it from your browsers."
echo "Recordings are NOT deleted."
echo
read -r -p "Remove MeetMe? [y/N] " reply
case "$reply" in
  [yY]|[yY][eE][sS]) ;;
  *) echo "Nothing was changed."; read -n 1 -s -r -p "Press any key to close this window…"; echo; exit 0 ;;
esac

./install/install.sh --uninstall
status=$?

echo
if [ "$status" -eq 0 ]; then
  echo "MeetMe: removed."
else
  echo "MeetMe: removal failed (exit $status). The messages above say why."
fi
read -n 1 -s -r -p "Press any key to close this window…"
echo
exit "$status"
