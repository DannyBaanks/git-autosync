#!/bin/sh
# Instala git-autosync para el usuario actual (sin root): programas en ~/.local/bin y
# unidades de systemd --user. Corre los gates antes de instalar; si fallan, no instala.
#
#   ./install.sh            gates + instalar + activar timers
#   ./install.sh --no-gates instalar sin correr los gates (no recomendado)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
if [ "${1:-}" != "--no-gates" ]; then
  "$here/tests/gates.sh" "$here/git-autosync" >/tmp/git-autosync-gates.$$ 2>&1 || {
    tail -n 20 /tmp/git-autosync-gates.$$; echo "gates en rojo: no se instala"; exit 1; }
  grep RESULTADO /tmp/git-autosync-gates.$$; rm -f /tmp/git-autosync-gates.$$
fi
mkdir -p "$HOME/.local/bin" "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
install -m 755 "$here/git-autosync" "$here/git-autosync-report" "$HOME/.local/bin/"
install -m 644 "$here"/systemd/*.service "$here"/systemd/*.timer "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/"
systemctl --user daemon-reload
systemctl --user enable --now git-autosync.timer git-autosync-report.timer
echo "instalado: $(git-autosync --version 2>/dev/null || "$HOME/.local/bin/git-autosync" --version)"
