#!/usr/bin/env bash
# Gates adversariales de git-autosync. Todo ocurre en un sandbox temporal:
# repos, remotos, config y estado propios. NUNCA toca repositorios reales.
#
#   gates.sh [ruta-al-git-autosync]      (por defecto: el de staging junto a este dir)
set -u
SUT=$(readlink -f "${1:-$(dirname "$(readlink -f "$0")")/../git-autosync}")
T=$(mktemp -d "${TMPDIR:-/tmp}/gas-gates.XXXXXXXX")
cd / || exit 1
export XDG_CONFIG_HOME="$T/cfg" XDG_STATE_HOME="$T/state"
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTOSYNC_NOTIFY_CMD="$T/notify.sh" GIT_AUTOSYNC_FETCH_TIMEOUT=20
export GIT_OPTIONAL_LOCKS=0   # que las huellas del arnes no reescriban el indice
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$T/cfg/git-autosync" "$T/state" "$T/root" "$T/remote" "$T/seed"
printf '[init]\n\tdefaultBranch = main\n[protocol "file"]\n\tallow = always\n[advice]\n\tdetachedHead = false\n' >"$GIT_CONFIG_GLOBAL"
printf '%s\n' "$T/root" >"$T/cfg/git-autosync/roots"
printf '#!/bin/sh\necho "$*" >>"%s/notify.log"\n' "$T" >"$T/notify.sh"; chmod +x "$T/notify.sh"
ROOT="$T/root"; ST="$T/state/git-autosync"
PASS=0; FAIL=0; FAILED=()

ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "condicion falsa: $2"; fi; }

# mk NAME -> remoto bare + clon en $ROOT/NAME con un commit inicial
mk() {
  local n=$1
  git init -q --bare "$T/remote/$n.git"
  git clone -q "$T/remote/$n.git" "$ROOT/$n" 2>/dev/null
  ( cd "$ROOT/$n" && echo base >f.txt && printf 'ign*\n' >.gitignore && git add -A && git commit -qm base && git push -q origin main ) 2>/dev/null
  git -C "$ROOT/$n" remote set-head origin main >/dev/null 2>&1
}
# upstream NAME [archivo] [contenido] -> nuevo commit en el remoto (via clon aparte)
upstream() {
  local n=$1 f=${2:-f.txt} c=${3:-new-$RANDOM}
  [ -d "$T/seed/$n" ] || git clone -q "$T/remote/$n.git" "$T/seed/$n" 2>/dev/null
  ( cd "$T/seed/$n" && git pull -q --ff-only 2>/dev/null; mkdir -p "$(dirname "$f")"; echo "$c" >"$f"; git add -A -f; git commit -qm "up $f"; git push -q origin main ) 2>/dev/null
}
rsha() { git -C "$T/remote/$1.git" rev-parse main; }
lsha() { git -C "$ROOT/$1" rev-parse "${2:-main}"; }
# Huella completa: refs locales (opcional: tambien remotas), HEAD, stash, estado y contenido de archivos.
snap() {
  local d=$1 withremote=${2:-0}
  { if [ "$withremote" = 1 ]; then git -C "$d" for-each-ref; else git -C "$d" for-each-ref refs/heads refs/tags refs/stash; fi
    git -C "$d" symbolic-ref -q HEAD || git -C "$d" rev-parse HEAD
    git -C "$d" stash list
    git -C "$d" status --porcelain --ignored
    ( cd "$d" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 -r sha256sum )
    [ "$withremote" = 1 ] && { cat "$d/.git/FETCH_HEAD" 2>/dev/null; stat -c %Y "$d/.git/index" 2>/dev/null; }
  } 2>/dev/null | sha256sum | cut -d' ' -f1
}
run()  { "$SUT" "$@" >"$T/out.txt" 2>&1; }
st()   { awk -F'\t' -v n="$1" '$2==n {print $1}' "$ST/last.tsv" 2>/dev/null; }
why()  { awk -F'\t' -v n="$1" '$2==n {print $8}' "$ST/last.tsv" 2>/dev/null; }
only() { printf '%s\n' "$1" >"$T/cfg/git-autosync/only"; }   # no usado por el SUT; documenta foco
FLAGS="$T/flags"; mkdir -p "$FLAGS"
paused() { rm -f "$FLAGS"/*; GIT_AUTOSYNC_TEST=1 GIT_AUTOSYNC_TEST_PAUSE_AT=before_mutate GIT_AUTOSYNC_TEST_PAUSE_SECS=${1:-4} GIT_AUTOSYNC_TEST_FLAGDIR="$FLAGS" "$SUT" >"$T/out.bg.txt" 2>&1 & BG=$!; }
# Espera a que el worker de ESE repo este realmente en pausa justo antes de modificar.
wait_paused() { local i; for i in $(seq 1 600); do [ -e "$FLAGS/$1" ] && return 0; sleep 0.1; done; echo "        (timeout esperando la pausa de $1)"; return 1; }

echo "SUT: $SUT ($("$SUT" --version))"; echo "sandbox: $T"

echo "G01 main limpia y atrasada, abierta -> fast-forward"
mk g01; upstream g01
run; check "G01 UPDATED" '[ "$(st g01)" = UPDATED ]'
check "G01 HEAD == origin" '[ "$(lsha g01 HEAD)" = "$(rsha g01)" ]'
check "G01 archivos actualizados y arbol limpio" '[ -z "$(git -C "$ROOT/g01" status --porcelain)" ] && [ "$(cat "$ROOT/g01/f.txt")" != base ]'

echo "G02 rama feature activa -> la feature no se toca; main avanza solo como ref"
mk g02; git -C "$ROOT/g02" checkout -q -b feat; echo wip >"$ROOT/g02/wip.txt"; echo edit >>"$ROOT/g02/f.txt"
upstream g02; before=$(git -C "$ROOT/g02" rev-parse feat); s0=$(cd "$ROOT/g02" && sha256sum f.txt wip.txt | sha256sum)
run; check "G02 UPDATED (ref)" '[ "$(st g02)" = UPDATED ]'
check "G02 main == origin" '[ "$(lsha g02 main)" = "$(rsha g02)" ]'
check "G02 feat intacta, HEAD sigue en feat" '[ "$(git -C "$ROOT/g02" rev-parse feat)" = "$before" ] && [ "$(git -C "$ROOT/g02" symbolic-ref --short HEAD)" = feat ]'
check "G02 archivos de trabajo (incl. cambios sin commit) identicos" '[ "$(cd "$ROOT/g02" && sha256sum f.txt wip.txt | sha256sum)" = "$s0" ]'

echo "G03/G04 main con cambios rastreados (unstaged / staged) -> DENY"
mk g03; echo local >>"$ROOT/g03/f.txt"; upstream g03 other.txt; s0=$(snap "$ROOT/g03")
mk g04; echo local >>"$ROOT/g04/f.txt"; git -C "$ROOT/g04" add f.txt; upstream g04 other.txt; s1=$(snap "$ROOT/g04")
run; check "G36 el historial registra los cambios de estado con motivo (incl. primera corrida)" 'grep -q "UPDATED.g01" "$ST/log.tsv" && grep -qP "\tDIRTY\tg03\tmain\t" "$ST/log.tsv"'
check "G03 DIRTY (unstaged)" '[ "$(st g03)" = DIRTY ]'; check "G03 nada cambio" '[ "$(snap "$ROOT/g03")" = "$s0" ]'
check "G04 DIRTY (staged)" '[ "$(st g04)" = DIRTY ]'; check "G04 nada cambio" '[ "$(snap "$ROOT/g04")" = "$s1" ]'

echo "G05/G06 archivo sin rastrear / ignorado que chocaria -> DENY"
mk g05; echo MIO >"$ROOT/g05/nuevo.txt"; upstream g05 nuevo.txt remoto; s0=$(snap "$ROOT/g05")
mk g06; echo SECRETO >"$ROOT/g06/ign.env"; upstream g06 ign.env remoto; s1=$(snap "$ROOT/g06")
# control: demostrar que git a secas SI pisaria el archivo ignorado
cp -a "$ROOT/g06" "$T/ctrl06"; git -C "$T/ctrl06" fetch -q origin 2>/dev/null; git -C "$T/ctrl06" merge -q --ff-only origin/main >/dev/null 2>&1
check "G06 control: 'git merge --ff-only' a secas PISA el archivo ignorado" '[ "$(cat "$T/ctrl06/ign.env")" = remoto ]'
run; check "G05 DIRTY (untracked)" '[ "$(st g05)" = DIRTY ]'; check "G05 archivo intacto, nada cambio" '[ "$(cat "$ROOT/g05/nuevo.txt")" = MIO ] && [ "$(snap "$ROOT/g05")" = "$s0" ]'
check "G06 DIRTY (ignorado)" '[ "$(st g06)" = DIRTY ]'; check "G06 archivo ignorado intacto, nada cambio" '[ "$(cat "$ROOT/g06/ign.env")" = SECRETO ] && [ "$(snap "$ROOT/g06")" = "$s1" ]'

echo "G07 archivo sin rastrear que NO interfiere -> avanza y lo conserva"
mk g07; echo MIO >"$ROOT/g07/notas.txt"; upstream g07
run; check "G07 UPDATED y archivo conservado" '[ "$(st g07)" = UPDATED ] && [ "$(cat "$ROOT/g07/notas.txt")" = MIO ]'

echo "G08 main abierta en OTRO worktree ocupado por un proceso -> DENY; libre -> avanza"
mk g08; git -C "$ROOT/g08" checkout -q -b feat; git -C "$ROOT/g08" worktree add -q "$ROOT/g08-main" main 2>/dev/null; upstream g08
( cd "$ROOT/g08-main" && exec sleep 300 ) & SL=$!; sleep 0.3; s0=$(snap "$ROOT/g08-main")
run; check "G08 BUSY (cwd de un proceso dentro del checkout)" '[ "$(st g08)" = BUSY ]'
check "G08 worktree intacto" '[ "$(snap "$ROOT/g08-main")" = "$s0" ] && [ "$(lsha g08 main)" != "$(rsha g08)" ]'
check "G08 un solo resultado para el grupo de worktrees" '[ "$(grep -c "g08" "$ST/last.tsv")" = 1 ]'
kill "$SL" 2>/dev/null; wait "$SL" 2>/dev/null
tail -f "$ROOT/g08-main/f.txt" >/dev/null 2>&1 & SL=$!; sleep 0.3
run; check "G08b BUSY (argumento de un proceso apunta al checkout)" '[ "$(st g08)" = BUSY ]'
kill "$SL" 2>/dev/null; wait "$SL" 2>/dev/null
upstream g08; run; check "G08c libre -> UPDATED en el worktree vinculado" '[ "$(st g08)" = UPDATED ] && [ "$(git -C "$ROOT/g08-main" rev-parse HEAD)" = "$(rsha g08)" ]'

echo "G09 commits locales exclusivos -> DENY (AHEAD) / G10 historial divergido -> DENY"
mk g09; ( cd "$ROOT/g09" && echo l >l.txt && git add -A && git commit -qm local ); s0=$(snap "$ROOT/g09")
mk g10; ( cd "$ROOT/g10" && echo l >l.txt && git add -A && git commit -qm local ); upstream g10; s1=$(snap "$ROOT/g10")
mk g29; upstream g29; run >/dev/null 2>&1
( cd "$T/seed/g29" && git commit -q --amend -m rewritten && git push -q -f origin main ) 2>/dev/null; s2=$(snap "$ROOT/g29")
run; check "G09 AHEAD" '[ "$(st g09)" = AHEAD ]'; check "G09 nada cambio" '[ "$(snap "$ROOT/g09")" = "$s0" ]'
check "G10 DIVERGED" '[ "$(st g10)" = DIVERGED ]'; check "G10 nada cambio" '[ "$(snap "$ROOT/g10")" = "$s1" ]'
check "G29 remoto reescrito (force-push) -> DIVERGED, local intacto" '[ "$(st g29)" = DIVERGED ] && [ "$(snap "$ROOT/g29")" = "$s2" ]'

echo "G11 sin origin -> SKIP / G12 remoto inaccesible -> error recuperable, el resto continua"
git init -q "$ROOT/g11"; ( cd "$ROOT/g11" && echo x >x && git add -A && git commit -qm x ); s0=$(snap "$ROOT/g11" 1)
mk g12a; rm -rf "$T/remote/g12a.git"
mk g12b; git -C "$ROOT/g12b" remote set-url origin "https://user:SECRETO123@127.0.0.1:1/x.git"; s1=$(snap "$ROOT/g12b")
mk g12c; upstream g12c
run; check "G11 NO_REMOTE, sin tocar config ni refs" '[ "$(st g11)" = NO_REMOTE ] && [ "$(snap "$ROOT/g11" 1)" = "$s0" ]'
check "G12a remoto desaparecido -> REMOTE_MISSING" '[ "$(st g12a)" = REMOTE_MISSING ]'
check "G12b host inalcanzable -> NETWORK_ERROR" '[ "$(st g12b)" = NETWORK_ERROR ]'
check "G12b nada cambio" '[ "$(snap "$ROOT/g12b")" = "$s1" ]'
check "G12c los demas repos se procesaron en la misma corrida" '[ "$(st g12c)" = UPDATED ]'
check "G26 credenciales de la URL no aparecen en salida, estado ni log" '! grep -rq SECRETO123 "$ST" "$T/out.txt"'

echo "G13 dos sincronizadores simultaneos -> el segundo no opera"
mk g13; upstream g13
paused 4; sleep 1.2
t0=$(date +%s%N); "$SUT" >"$T/out2.txt" 2>&1; rc=$?; ms=$(( ($(date +%s%N)-t0)/1000000 ))
check "G13 segunda corrida sale sin operar (rc=0, mensaje de candado)" '[ $rc = 0 ] && grep -q "ya esta corriendo" "$T/out2.txt"'
check "G13 la segunda no espero ni toco nada (${ms}ms)" '[ $ms -lt 1500 ]'
"$SUT" __one "$ROOT/g13" >"$T/one.txt" 2>&1
check "G13b candado por repo: un worker directo sobre el mismo repo -> BUSY" 'grep -q "^BUSY" "$T/one.txt"'
wait "$BG"; check "G13 la primera termino y actualizo una sola vez" '[ "$(st g13)" = UPDATED ] && [ "$(git -C "$ROOT/g13" reflog main | grep -c .)" -le 3 ]'

echo "G14 commit creado entre la comprobacion y el fast-forward (rama abierta) -> DENY"
mk g14; upstream g14; paused 8; wait_paused g14
( cd "$ROOT/g14" && echo agente >agente.txt && git add -A && git commit -qm "commit de agente" ); mine=$(lsha g14 HEAD)
wait "$BG"; check "G14 no UPDATED (BUSY)" '[ "$(st g14)" = BUSY ]'
check "G14 commit del agente conservado y HEAD intacto" '[ "$(lsha g14 HEAD)" = "$mine" ] && [ -f "$ROOT/g14/agente.txt" ]'

echo "G15 la rama cambia durante la pausa (rama NO abierta) -> CAS/revalidacion DENY"
mk g15; git -C "$ROOT/g15" checkout -q -b feat; upstream g15; paused 8; wait_paused g15
c=$(git -C "$ROOT/g15" commit-tree -p main -m concurrente "main^{tree}"); git -C "$ROOT/g15" update-ref refs/heads/main "$c"
wait "$BG"; check "G15a CAS rechazado: la ref conserva el commit concurrente" '[ "$(st g15)" = BUSY ] && [ "$(lsha g15 main)" = "$c" ]'
mk g15b; git -C "$ROOT/g15b" checkout -q -b feat; upstream g15b; paused 8; wait_paused g15b
git -C "$ROOT/g15b" checkout -q main; old=$(lsha g15b main)
wait "$BG"; check "G15b main se abrio durante la pausa -> BUSY, ref y arbol coherentes" '[ "$(st g15b)" = BUSY ] && [ "$(lsha g15b main)" = "$old" ] && [ -z "$(git -C "$ROOT/g15b" status --porcelain)" ]'

echo "G16 un agente empieza a editar despues de la comprobacion inicial -> DENY"
mk g16; upstream g16; paused 8; wait_paused g16; echo "edicion en curso" >>"$ROOT/g16/f.txt"
wait "$BG"; check "G16 DIRTY y la edicion sigue ahi" '[ "$(st g16)" = DIRTY ] && grep -q "edicion en curso" "$ROOT/g16/f.txt" && [ "$(lsha g16 HEAD)" != "$(rsha g16)" ]'

echo "G17 otro proceso mantiene un lock de git / G31 operacion a medias / G32 rebase de main"
mk g17; upstream g17; : >"$ROOT/g17/.git/index.lock"
mk g31; upstream g31; git -C "$ROOT/g31" rev-parse HEAD >"$ROOT/g31/.git/MERGE_HEAD"
mk g32; git -C "$ROOT/g32" checkout -q --detach; upstream g32; mkdir "$ROOT/g32/.git/rebase-merge"; echo refs/heads/main >"$ROOT/g32/.git/rebase-merge/head-name"
run; check "G17 BUSY y el lock ajeno sigue ahi" '[ "$(st g17)" = BUSY ] && [ -e "$ROOT/g17/.git/index.lock" ] && [ "$(lsha g17 main)" != "$(rsha g17)" ]'
check "G31 BUSY (MERGE_HEAD)" '[ "$(st g31)" = BUSY ] && [ "$(lsha g31 main)" != "$(rsha g31)" ]'
check "G32 BUSY (main en rebase, HEAD separado)" '[ "$(st g32)" = BUSY ] && [ "$(lsha g32 main)" != "$(rsha g32)" ]'
rm -f "$ROOT/g17/.git/index.lock" "$ROOT/g31/.git/MERGE_HEAD"; rm -rf "$ROOT/g32/.git/rebase-merge"

echo "G18 SIGTERM antes de modificar -> ninguna modificacion, candado liberado, la siguiente corrida avanza"
mk g18; upstream g18; s0=$(snap "$ROOT/g18"); paused 8; wait_paused g18; kill -TERM "$BG"; wait "$BG"
check "G18 nada modificado tras SIGTERM" '[ "$(snap "$ROOT/g18")" = "$s0" ]'
check "G18 reportado como detenido, no como exito" 'grep -q "detenida por senal" "$T/out.bg.txt" && [ "$(st g18)" != UPDATED ]'
run; check "G18 siguiente corrida: UPDATED" '[ "$(st g18)" = UPDATED ]'

echo "G19 SIGKILL en mitad del fast-forward de un repo grande -> sin perdida de trabajo"
mk g19; ( cd "$ROOT/g19" && mkdir big && for i in $(seq 1 40000); do echo "v1-$i" >"big/$i.txt"; done && git add -A && git commit -qm big && git push -q origin main ) 2>/dev/null
[ -d "$T/seed/g19" ] || git clone -q "$T/remote/g19.git" "$T/seed/g19" 2>/dev/null
( cd "$T/seed/g19" && for i in $(seq 1 40000); do echo "v2-$i" >"big/$i.txt"; done && git add -A && git commit -qm big2 && git push -q origin main ) 2>/dev/null
echo "trabajo sin rastrear" >"$ROOT/g19/mio.txt"; old=$(lsha g19 HEAD); new=$(rsha g19)
"$SUT" >"$T/out.bg.txt" 2>&1 & BG=$!
hit=0
# Patron unico del sandbox; se verifica que el PID sea un `git` antes de matarlo.
for _ in $(seq 1 3000); do
  for pid in $(pgrep -f -- "-C $ROOT/g19 merge --ff-only" 2>/dev/null); do
    if [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = git ]; then sleep 0.03; kill -9 "$pid" 2>/dev/null && hit=1; fi
  done
  [ $hit = 1 ] && break
  kill -0 "$BG" 2>/dev/null || break
done
wait "$BG"
h=$(lsha g19 HEAD); mixed=$(git -C "$ROOT/g19" status --porcelain --untracked-files=no | wc -l)
echo "        (kill acertado=$hit; HEAD=$([ "$h" = "$old" ] && echo viejo || echo nuevo); archivos rastreados en estado intermedio=$mixed; estado=$(st g19))"
check "G19 el SIGKILL alcanzo al merge en curso (si no, el gate no demuestra nada)" '[ $hit = 1 ]'
check "G19 HEAD es el commit viejo o el nuevo, nunca otra cosa" '[ "$h" = "$old" ] || [ "$h" = "$new" ]'
check "G19 archivo sin rastrear del usuario intacto" '[ "$(cat "$ROOT/g19/mio.txt")" = "trabajo sin rastrear" ]'
badc=0; for i in 1 777 6000 11999 25000 40000; do c=$(cat "$ROOT/g19/big/$i.txt"); [ "$c" = "v1-$i" ] || [ "$c" = "v2-$i" ] || badc=1; done
check "G19 cada archivo rastreado es la version vieja o la nueva (recuperable desde git)" '[ $badc = 0 ]'
check "G19 ambos commits siguen existiendo en el repo" 'git -C "$ROOT/g19" cat-file -e "$old" && git -C "$ROOT/g19" cat-file -e "$new"'
if [ "$mixed" -gt 0 ]; then
  check "G19 la corrida no lo reporto como exito" '[ "$(st g19)" != UPDATED ]'
  s0=$(snap "$ROOT/g19"); run
  check "G19 siguiente corrida: INTERRUPTED y no toca nada mas" '[ "$(st g19)" = INTERRUPTED ] && [ "$(snap "$ROOT/g19")" = "$s0" ]'
fi
rm -rf "$ROOT/g19" "$ST/inflight"/*    # limpieza del sandbox para los gates siguientes

echo "G22 hooks del repo no se ejecutan / G25 autostash configurado no produce stash"
mk g22; printf '#!/bin/sh\ntouch "%s/HOOK_RAN"\n' "$T" >"$ROOT/g22/.git/hooks/post-merge"; cp "$ROOT/g22/.git/hooks/post-merge" "$ROOT/g22/.git/hooks/reference-transaction"; chmod +x "$ROOT/g22/.git/hooks/"*; upstream g22
mk g25; git -C "$ROOT/g25" config merge.autoStash true; git -C "$ROOT/g25" config rebase.autoStash true; git -C "$ROOT/g25" config pull.rebase true; echo local >>"$ROOT/g25/f.txt"; upstream g25 other.txt
rm -f "$T/HOOK_RAN"; run
check "G22 UPDATED sin ejecutar hooks" '[ "$(st g22)" = UPDATED ] && [ ! -e "$T/HOOK_RAN" ]'
check "G25 DIRTY, sin stash, cambio local intacto" '[ "$(st g25)" = DIRTY ] && [ -z "$(git -C "$ROOT/g25" stash list)" ] && grep -q local "$ROOT/g25/f.txt"'

echo "G23 refspec tipo mirror (fetch pisaria ramas locales) -> se omite"
mk g23; ( cd "$ROOT/g23" && echo l >l.txt && git add -A && git commit -qm local ); git -C "$ROOT/g23" config remote.origin.fetch '+refs/heads/*:refs/heads/*'; upstream g23; s0=$(snap "$ROOT/g23" 1)
run; check "G23 UNKNOWN y ninguna ref cambio" '[ "$(st g23)" = UNKNOWN ] && [ "$(snap "$ROOT/g23" 1)" = "$s0" ]'

echo "G24 rutas con espacios y Unicode; symlink al mismo repo no duplica"
mk "g24 ñandú 東京"; ln -s "$ROOT/g24 ñandú 東京" "$ROOT/g24-link"; upstream "g24 ñandú 東京"
run; check "G24 UPDATED con espacios/Unicode" '[ "$(st "g24 ñandú 東京")" = UPDATED ]'
check "G24 un solo resultado pese al symlink" '[ "$(grep -c "g24" "$ST/last.tsv")" = 1 ]'

echo "G27 rama local que sigue a otro upstream -> no se infiere"
mk g27; git -C "$ROOT/g27" remote add other "$T/remote/g01.git"; git -C "$ROOT/g27" config branch.main.remote other; upstream g27; s0=$(snap "$ROOT/g27")
run; check "G27 UNKNOWN y nada cambio" '[ "$(st g27)" = UNKNOWN ] && [ "$(snap "$ROOT/g27")" = "$s0" ]'

echo "G30 exclude / pin / G33 no se podan refs remotas / G34 HEAD separado"
mk g30-BACKUP; upstream g30-BACKUP; printf '*BACKUP*\n' >"$T/cfg/git-autosync/exclude"
mk g30pin; upstream g30pin; printf 'g30pin\n' >"$T/cfg/git-autosync/pin"
mk g33; ( cd "$ROOT/g33" && git checkout -q -b tmp && git push -q origin tmp && git checkout -q main ) 2>/dev/null; git -C "$ROOT/g33" fetch -q origin; git -C "$T/remote/g33.git" branch -D tmp >/dev/null; git -C "$ROOT/g33" config fetch.prune true
mk g34; git -C "$ROOT/g34" checkout -q --detach; upstream g34; h=$(lsha g34 HEAD)
run; check "G30 excluido: sin resultado y sin tocar" '[ -z "$(st g30-BACKUP)" ] && [ "$(lsha g30-BACKUP main)" != "$(rsha g30-BACKUP)" ]'
check "G30 pin: PINNED, rama sin mover, origin/main si actualizado" '[ "$(st g30pin)" = PINNED ] && [ "$(lsha g30pin main)" != "$(rsha g30pin)" ] && [ "$(lsha g30pin origin/main)" = "$(rsha g30pin)" ]'
check "G33 la ref remota borrada en origin se conserva (sin prune, aun con fetch.prune=true)" 'git -C "$ROOT/g33" rev-parse -q --verify refs/remotes/origin/tmp >/dev/null'
check "G34 HEAD separado intacto y main avanzada como ref" '[ "$(lsha g34 HEAD)" = "$h" ] && [ "$(lsha g34 main)" = "$(rsha g34)" ] && [ -z "$(git -C "$ROOT/g34" status --porcelain)" ]'

echo "G21 dry-run no modifica NADA (refs locales y remotas, FETCH_HEAD, indice, archivos)"
mk g21a; upstream g21a; mk g21b; git -C "$ROOT/g21b" checkout -q -b feat; upstream g21b; git -C "$ROOT/g21b" fetch -q origin
all0=$(for d in "$ROOT"/*/; do [ -e "$d/.git" ] && [ ! -L "${d%/}" ] && snap "${d%/}" 1; done | sha256sum); st0=$(find "$ST" -type f ! -name lock | sort | xargs sha256sum | sha256sum)
"$SUT" --dry-run >"$T/dry.txt" 2>&1
all1=$(for d in "$ROOT"/*/; do [ -e "$d/.git" ] && [ ! -L "${d%/}" ] && snap "${d%/}" 1; done | sha256sum); st1=$(find "$ST" -type f ! -name lock | sort | xargs sha256sum | sha256sum)
check "G21 huella de TODOS los repos identica tras dry-run" '[ "$all0" = "$all1" ]'
check "G21 el estado/log del sincronizador tampoco cambio" '[ "$st0" = "$st1" ]'
check "G21 distingue observado de prediccion (WOULD_FETCH / WOULD_UPDATE)" 'grep -q "WOULD_FETCH .*g21a" "$T/dry.txt" && grep -q "WOULD_UPDATE .*g21b" "$T/dry.txt"'

echo "G20 ejecucion repetida sin novedades -> idempotente / G28 notificaciones no se repiten"
run; all0=$(for d in "$ROOT"/*/; do [ -e "$d/.git" ] && [ ! -L "${d%/}" ] && snap "${d%/}" 1; done | sha256sum); n0=$(wc -l <"$T/notify.log"); l0=$(grep -vc $'\tRUN\t' "$ST/log.tsv")
run; all1=$(for d in "$ROOT"/*/; do [ -e "$d/.git" ] && [ ! -L "${d%/}" ] && snap "${d%/}" 1; done | sha256sum); n1=$(wc -l <"$T/notify.log"); l1=$(grep -vc $'\tRUN\t' "$ST/log.tsv")
check "G20 segunda corrida no cambia nada en ningun repo" '[ "$all0" = "$all1" ]'
check "G20 ningun UPDATED en la segunda corrida" '! grep -q "^UPDATED" "$ST/last.tsv"'
check "G28 problemas identicos no vuelven a notificar ($n0 -> $n1) ni a escribir historial ($l0 -> $l1)" '[ "$n0" = "$n1" ] && [ "$l0" = "$l1" ]'
check "G28 hubo notificaciones de bloqueos nuevos en corridas anteriores" 'grep -q "Repos bloqueados" "$T/notify.log"'

echo "G37 clon de una sola rama sin la rama por defecto -> NO_LOCAL, no se crea nada"
mk g37; ( cd "$ROOT/g37" && git checkout -q -b docs && git push -q origin docs ) 2>/dev/null; rm -rf "$ROOT/g37"
git clone -q --single-branch --branch docs "$T/remote/g37.git" "$ROOT/g37" 2>/dev/null; upstream g37; s0=$(snap "$ROOT/g37")
run; check "G37 NO_LOCAL y ninguna rama creada" '[ "$(st g37)" = NO_LOCAL ] && [ "$(snap "$ROOT/g37")" = "$s0" ] && ! git -C "$ROOT/g37" rev-parse -q --verify refs/heads/main >/dev/null'

echo "G40 report: solo lectura y detecta lo que solo vive aqui"
export GIT_AUTOSYNC_REPO_ENGINE=/nonexistent
mk g40; ( cd "$ROOT/g40" && git checkout -q -b nunca-subida && echo a >a.txt && git add -A && git commit -qm a && echo b >b.txt && git add -A && git commit -qm b && echo wip >>f.txt && git stash -q && echo sucio >>f.txt )
mk g40dyn; printf 'phase = "building"\n' >"$ROOT/g40dyn/.repo-engine.toml"; fake="$T/fake-repo-engine.py"; : >"$fake"
printf '#!/bin/sh\nENGINE="${ISYCO_REPO_ENGINE:-%s}"\n[ -f "$ENGINE" ] || exit 0\npython3 "$ENGINE" gate commit --repo "$(git rev-parse --show-toplevel)"\n' "$fake" | tee "$ROOT/g40dyn/.git/hooks/pre-commit" >"$ROOT/g40dyn/.git/hooks/pre-push"
chmod +x "$ROOT/g40dyn/.git/hooks/pre-commit"; chmod -x "$ROOT/g40dyn/.git/hooks/pre-push"   # pre-push SIN permiso de ejecucion
mk "g40 espacio"; printf 'phase = "building"\n' >"$ROOT/g40 espacio/.repo-engine.toml"; fake2="$T/dir con espacio/repo-engine.py"; mkdir -p "$T/dir con espacio"; : >"$fake2"
for h in pre-commit pre-push; do printf '#!/bin/sh\npython3 "%s" gate x --repo "%s"\n' "$fake2" "$ROOT/g40 espacio" >"$ROOT/g40 espacio/.git/hooks/$h"; chmod +x "$ROOT/g40 espacio/.git/hooks/$h"; done
mk g40hook; printf 'phase = "building"\n' >"$ROOT/g40hook/.repo-engine.toml"
printf '#!/bin/sh\n"%s" "C:/Dev/repo-engine.py" gate commit --repo "C:/x"\n' "C:/Us""ers/x/python.exe" >"$ROOT/g40hook/.git/hooks/pre-commit"; chmod +x "$ROOT/g40hook/.git/hooks/pre-commit"
run
all0=$(for d in "$ROOT"/*/; do [ -e "$d/.git" ] && [ ! -L "${d%/}" ] && snap "${d%/}" 1; done | sha256sum)
"$SUT" report >"$T/report.txt" 2>&1; rrc=$?
all1=$(for d in "$ROOT"/*/; do [ -e "$d/.git" ] && [ ! -L "${d%/}" ] && snap "${d%/}" 1; done | sha256sum)
check "G40 report termina bien y no modifica ningun repo (refs, indice, archivos, stash)" '[ $rrc = 0 ] && [ "$all0" = "$all1" ]'
check "G40 detecta rama nunca subida con sus 2 commits" 'grep -qE "g40 +nunca-subida +\+2 .*SIN UPSTREAM" "$T/report.txt"'
check "G40 detecta repo sin remoto, stash y checkout con cambios" 'grep -qE "^ +g11 " "$T/report.txt" && grep -qE "g40 +1 stash" "$T/report.txt" && grep -qE "g40 .*nunca-subida.*modificados=1" "$T/report.txt"'
check "G40 detecta hook de repo-engine roto (ruta de Windows) y hook ausente" 'grep -qE "g40hook .*pre-commit=ROTO\(ruta inexistente: C:/.*pre-push=FALTA" "$T/report.txt"'
check "G40 hook con rutas dinamicas valido = OK; sin permiso de ejecucion = ROTO" 'grep -qE "g40dyn .*pre-commit=OK +pre-push=ROTO\(sin permiso de ejecucion" "$T/report.txt"'
check "G40 rutas entre comillas con espacios existentes = OK" 'grep -qE "g40 espacio +hooks OK" "$T/report.txt"'
check "G40 main con commits propios y repos bloqueados aparecen" 'grep -qE "AHEAD +g09 " "$T/report.txt" && grep -qE "g03 +DIRTY +desde hace" "$T/report.txt"'

echo "G45 reporte respeta core.hooksPath (.githooks) y husky (.husky/_ -> .husky/<hook>)"
mk g45gh; printf 'phase = "building"\n' >"$ROOT/g45gh/.repo-engine.toml"; mkdir -p "$ROOT/g45gh/.githooks"
for h in pre-commit pre-push; do printf '#!/bin/sh\nif command -v repo-engine >/dev/null; then repo-engine gate x; fi\n' >"$ROOT/g45gh/.githooks/$h"; chmod +x "$ROOT/g45gh/.githooks/$h"; done
git -C "$ROOT/g45gh" config core.hooksPath .githooks
mk g45hk; printf 'phase = "building"\n' >"$ROOT/g45hk/.repo-engine.toml"; mkdir -p "$ROOT/g45hk/.husky/_"
for h in pre-commit pre-push; do printf '#!/usr/bin/env sh\n. "$(dirname "$0")/h"' >"$ROOT/g45hk/.husky/_/$h"; chmod +x "$ROOT/g45hk/.husky/_/$h"; done
printf 'repo-engine gate commit\n' >"$ROOT/g45hk/.husky/pre-commit"          # husky: sin bit de ejecucion, a proposito
git -C "$ROOT/g45hk" config core.hooksPath .husky/_
run; "$SUT" report --no-audit >"$T/report45.txt" 2>&1
check "G45 .githooks con repo-engine = hooks OK" 'grep -qE "g45gh +hooks OK" "$T/report45.txt"'
check "G45 husky: script con repo-engine = OK; script ausente = FALTA" 'grep -qE "g45hk +pre-commit=OK +pre-push=FALTA\(husky sin script\)" "$T/report45.txt"'

echo "G41 aviso de commit directo en main: solo en repos que integran por PR, y una sola vez"
mk g41pr; for k in 1 2 3; do upstream g41pr "pr$k.txt"; ( cd "$T/seed/g41pr" && git commit -q --amend -m "Merge pull request #$k from x/y" && git push -q -f origin main ) 2>/dev/null; done
mk g41solo; upstream g41solo
run; : >"$T/notify.log"
( cd "$ROOT/g41pr" && echo d >d.txt && git add -A && git commit -qm directo ); ( cd "$ROOT/g41solo" && echo d >d.txt && git add -A && git commit -qm directo )
run; check "G41 avisa del repo que integra por PR" 'grep -q "Commit directo.*g41pr" "$T/notify.log"'
check "G41 no avisa del repo de push directo" '! grep -q "g41solo" "$T/notify.log"'
check "G41 queda en el historial" 'grep -qP "\tDIRECT_COMMIT\tg41pr\t" "$ST/log.tsv"'
: >"$T/notify.log"; run; check "G41 no se repite en la corrida siguiente" '! grep -q "Commit directo" "$T/notify.log"'

echo "G42 alarma de bloqueo prolongado: a los 3 dias, sin repetir, y recordatorio a los 7 mas"
for k in a b c; do mk "g42$k"; echo local >>"$ROOT/g42$k/f.txt"; upstream "g42$k" other.txt; done   # >10 bloqueados: ejercita el recorte
run; nblk=$(grep -c . "$ST/blocked.tsv")
t0=$(date +%s); : >"$T/notify.log"
GIT_AUTOSYNC_TEST=1 GIT_AUTOSYNC_TEST_NOW=$((t0+86400)) "$SUT" >/dev/null 2>&1
check "G42 a 1 dia: sin alarma" '! grep -q "desde hace dias" "$T/notify.log"'
GIT_AUTOSYNC_TEST=1 GIT_AUTOSYNC_TEST_NOW=$((t0+4*86400)) "$SUT" >/dev/null 2>&1
check "G42 a 4 dias: alarma con el repo y los dias" 'grep -q "desde hace dias" "$T/notify.log" && grep -qE "g03: DIRTY desde hace [34] dias" "$T/notify.log"'
check "G42 con $nblk bloqueados (>10) dice cuantos faltan en vez de ocultarlos" '[ "$nblk" -gt 10 ] && grep -qE "… y $((nblk-10)) mas" "$T/notify.log"'
n0=$(grep -c "desde hace dias" "$T/notify.log"); GIT_AUTOSYNC_TEST=1 GIT_AUTOSYNC_TEST_NOW=$((t0+4*86400+3600)) "$SUT" >/dev/null 2>&1
check "G42 una hora despues: no se repite" '[ "$(grep -c "desde hace dias" "$T/notify.log")" = "$n0" ]'
GIT_AUTOSYNC_TEST=1 GIT_AUTOSYNC_TEST_NOW=$((t0+12*86400)) "$SUT" >/dev/null 2>&1
check "G42 a 12 dias: recordatorio" '[ "$(grep -c "desde hace dias" "$T/notify.log")" -gt "$n0" ]'
git -C "$ROOT/g03" checkout -q -- f.txt 2>/dev/null; GIT_AUTOSYNC_TEST=1 GIT_AUTOSYNC_TEST_NOW=$((t0+12*86400+60)) "$SUT" >/dev/null 2>&1
check "G42 al desbloquearse sale de la lista" '! grep -qP "^g03\t" "$ST/blocked.tsv"'

echo "G44 archivado: no contacta el remoto, no alarma, el reporte lo lista como unica copia"
mk g44; ( cd "$ROOT/g44" && echo x >solo.txt && git add -A && git commit -qm "solo local" ); rm -rf "$T/remote/g44.git"
run; check "G44 sin archivar: REMOTE_MISSING (alarma)" '[ "$(st g44)" = REMOTE_MISSING ]'
"$SUT" archive g44 >/dev/null; "$SUT" archive g44 >"$T/arch2.txt"
check "G44 archive es idempotente" 'grep -q "ya estaba" "$T/arch2.txt" && [ "$(grep -cx g44 "$T/cfg/git-autosync/archived")" = 1 ]'
git -C "$ROOT/g44" remote set-url origin "https://user:SECRETO44@127.0.0.1:1/x.git"; s0=$(snap "$ROOT/g44" 1); : >"$T/notify.log"
run; check "G44 archivado: ARCHIVED y ninguna ref cambio (no hubo fetch)" '[ "$(st g44)" = ARCHIVED ] && [ "$(snap "$ROOT/g44" 1)" = "$s0" ]'
check "G44 archivado: no notifica como bloqueo ni entra en blocked" '! grep -q "g44" "$T/notify.log" && ! grep -qP "^g44\t" "$ST/blocked.tsv"'
"$SUT" report --no-audit >"$T/report44.txt" 2>&1
check "G44 reporte: aparece como unica copia con su commit sin subir" 'grep -qE "^ +g44 .*\+1 commits que nunca se subieron" "$T/report44.txt" && grep -q "UNICA COPIA" "$T/report44.txt"'

echo "G47 report --local: solo lo que existe unicamente aqui, con commits y comando sugerido, sin tocar nada"
mk g47a; mk g47b; mk g47c
( cd "$ROOT/g47a" && git checkout -q -b feat-sola && echo 1 >a.txt && git add -A && git commit -qm "primer cambio solo local" && echo 2 >b.txt && git add -A && git commit -qm "segundo cambio solo local" )
( cd "$ROOT/g47b" && git checkout -q -b con-upstream && git push -q -u origin con-upstream 2>/dev/null && echo 3 >c.txt && git add -A && git commit -qm "adelantada del upstream" )
( cd "$ROOT/g47b" && git checkout -q -b otra-rama && git branch --set-upstream-to=origin/main otra-rama -q && echo 4 >d.txt && git add -A && git commit -qm "upstream con otro nombre" )
git -C "$ROOT/g47c" remote remove origin
run; s47=$(for n in g47a g47b g47c; do snap "$ROOT/$n" 1; done | sha256sum)
"$SUT" report --local >"$T/local47.txt" 2>&1; rc=$?
s47b=$(for n in g47a g47b g47c; do snap "$ROOT/$n" 1; done | sha256sum)
check "G47 --local termina bien y no modifica ningun repo" '[ $rc = 0 ] && [ "$s47" = "$s47b" ]'
check "G47 lista la rama nunca subida con +2, sus commits y push -u" 'grep -qE "g47a +feat-sola +\+2 .*SIN UPSTREAM" "$T/local47.txt" && grep -q "segundo cambio solo local" "$T/local47.txt" && grep -qE "\\$ git -C .*g47a.* push -u origin feat-sola" "$T/local47.txt"'
check "G47 rama con upstream adelantada: push sin -u" 'grep -qE "g47b +con-upstream +\+1 .*upstream origin/con-upstream" "$T/local47.txt" && grep -qE "\\$ git -C .*g47b.* push origin con-upstream$" "$T/local47.txt"'
check "G47 upstream con otro nombre: push <remote> rama:destino" 'grep -qE "\\$ git -C .*g47b.* push origin otra-rama:main$" "$T/local47.txt"'
check "G47 repo sin remoto aparece como unica copia y sin comando" 'grep -qE "^  g47c +sin_remoto" "$T/local47.txt" && ! grep -q "g47c.* push" "$T/local47.txt"'
check "G47 un repo al dia no aparece" '! grep -q "g47-nada" "$T/local47.txt" && ! grep -qE "^  g01 " "$T/local47.txt"'

echo "G48 report --html: panel autocontenido, solo lectura, datos escapados"
mk g48; ( cd "$ROOT/g48" && git checkout -q -b rama-xss && echo 1 >a.txt && git add -A && git commit -qm 'x</script><img src=x onerror=alert(1)> & "q"' && echo 2 >b.txt && git add -A && git commit -qm "segundo" )
run; s48=$(snap "$ROOT/g48" 1); P48="$T/panel48.html"
"$SUT" report --html "$P48" >"$T/html48.txt" 2>&1; rc=$?
check "G48 --html termina bien, escribe el archivo con permisos 600 y no toca ningun repo" '[ $rc = 0 ] && [ -s "$P48" ] && [ "$(stat -c %a "$P48")" = 600 ] && [ "$(snap "$ROOT/g48" 1)" = "$s48" ] && [ ! -e "$P48.tmp" ]'
check "G48 el mensaje hostil no aparece crudo (no rompe el <script> de datos)" '! grep -q "</script><img" "$P48" && grep -q "u003c/script" "$P48"'
check "G48 sin recursos externos (ni scripts ni estilos ni fuentes remotas)" '! grep -qE "(src|href)=\"https?://|@import|<link " "$P48"'
check "G48 los datos son JSON valido y traen la rama, +2 y el mensaje intacto" 'python3 - "$P48" <<PYEOF
import json,re,sys
h=open(sys.argv[1],encoding="utf-8").read()
blob=re.search(r"<script id=\"data\" type=\"application/json\">(.*?)</script>",h,re.S).group(1)
d=json.loads(blob)
r=[x for x in d["local"] if x["repo"]=="g48" and x["branch"]=="rama-xss"]
sys.exit(0 if r and r[0]["n"]==2 and any("onerror=alert(1)" in s for s in r[0]["subjects"]) else 1)
PYEOF'
if command -v node >/dev/null 2>&1; then
  python3 - "$P48" "$T/panel48.js" <<'PYEOF'
import re,sys
h=open(sys.argv[1],encoding="utf-8").read()
open(sys.argv[2],"w").write(re.findall(r"<script>(.*?)</script>",h,re.S)[0])
PYEOF
  check "G48 el JS del panel es sintacticamente valido" 'node --check "$T/panel48.js"'
  check "G48 el JS pinta con textContent y nunca con innerHTML" '! grep -qE "innerHTML|outerHTML|insertAdjacentHTML|document\.write|eval\(" "$T/panel48.js"'
fi

echo "G35 autoridad: el codigo del SUT no invoca comandos prohibidos"
code=$(grep -vE '^\s*#' "$SUT")
check "G35 sin reset/clean/stash/rebase/push/checkout/switch/pull/--force/prune activo" \
  '! grep -qE "(^|[^-[:alnum:]])(g|git)( -[cC] [^ ]+)* +(reset|clean|stash|rebase|push|checkout|switch|pull|gc|restore|rm|branch|commit|cherry-pick|revert|am|apply)( |$)" <<<"$code" && ! grep -E "(^|[^[:alnum:]_])(g|git) " <<<"$code" | grep -qE -- "--force|--hard|[^-]--prune|(push|checkout|clean|fetch|merge|update-ref|branch) +(-[a-zA-Z]+ +)*-[a-zA-Z]*f"'
check "G35 los unicos comandos git que escriben son fetch, merge --ff-only y update-ref" \
  '[ "$(grep -oE "(fetch|merge|update-ref) " <<<"$code" | sort -u | tr -d "\n")" = "fetch merge update-ref " ] && grep -q -- "merge --ff-only" <<<"$code"'

rep="$(dirname "$SUT")/git-autosync-report"
report_git_ok() {
  local f=$1 bad
  bad=$(grep -oE 'git\([^,]+, "[a-z-]+"' "$f" | sed -E 's/.*"([a-z-]+)"$/\1/' | sort -u \
        | grep -vxE 'worktree|rev-list|log|for-each-ref|rev-parse|status')
  [ -z "$bad" ] || { echo "        subcomando no permitido: $bad"; return 1; }
  ! grep -E '"worktree"' "$f" | grep -qE '"(add|move|remove|prune|repair|lock|unlock)"'
}
check "G43 el reporte solo llama a git con subcomandos de lectura (worktree solo 'list')" 'report_git_ok "$rep"'
check "G43 el reporte no ejecuta git por otra via (un unico helper)" '[ "$(grep -c "\"git\"" "$rep")" = 1 ]'

echo
echo "RESULTADO: $PASS PASS, $FAIL FAIL"
[ $FAIL -gt 0 ] && printf '  fallo: %s\n' "${FAILED[@]}"
echo "sandbox conservado en: $T"
[ $FAIL = 0 ]
