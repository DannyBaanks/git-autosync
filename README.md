# git-autosync

Mantiene al día la rama por defecto (`main`, `master`, …) de todos tus clones locales con
GitHub, **solo por fast-forward y solo cuando se puede demostrar que es seguro**. Pensado
para quien trabaja con muchos repos, PRs y agentes en paralelo y se olvida de hacer `pull`.

> Un repo bloqueado con una explicación correcta es un resultado válido.
> Un repo actualizado a costa de trabajo local es un fallo crítico.

## Qué hace (y qué nunca hace)

Cada 15 minutos (timer de `systemd --user`), por cada repo bajo las carpetas vigiladas:

1. `git fetch` (sin prune, sin hooks, sin gc).
2. Si la rama por defecto **no está abierta** en ningún worktree: avanza la referencia con
   `update-ref` atómico (compara y cambia el SHA esperado). Ningún archivo cambia.
3. Si **está abierta**: `merge --ff-only` solo si el árbol está limpio, ningún archivo sin
   rastrear o ignorado chocaría, no hay merge/rebase a medias ni `index.lock`, y ningún
   proceso tiene ese checkout como cwd, ejecutable o argumento. Todo se revalida justo antes.
4. Cualquier otra cosa → **no toca nada** y explica por qué.

Nunca: `reset`, `clean`, `stash`, `rebase`, `push`, `checkout`/`switch`, merge commits,
`--force`, crear ramas, reiniciar servicios.

| Estado | Significado |
|---|---|
| `UPDATED` | avanzó por fast-forward |
| `UP_TO_DATE` | ya estaba igual que origin |
| `AHEAD` / `DIVERGED` | tu rama tiene commits propios: decisión humana |
| `DIRTY` | cambios sin commit, o un archivo local chocaría con lo que llega |
| `BUSY` | otro proceso usa el checkout, hay un lock, o algo cambió durante la corrida |
| `PINNED` | repo fijado: solo fetch |
| `ARCHIVED` | remoto borrado a propósito: no se contacta; esta copia es la única |
| `NO_REMOTE`, `REMOTE_MISSING`, `AUTH_ERROR`, `NETWORK_ERROR`, `NO_LOCAL`, `UNKNOWN`, `INTERRUPTED` | se omiten, con el motivo |

## Reporte diario (solo lectura)

`git-autosync report` (y un timer diario a las 10:00, con aviso de escritorio si cambió):

- trabajo que **solo vive en tu máquina**: repos sin remoto, remotos caídos, archivados,
  commits que no están en ningún remoto, stashes, checkouts con cambios sin commit;
- ramas por defecto con commits propios (y aviso cuando nace un commit directo en `main`
  de un repo que integra por PR);
- repos bloqueados desde hace días;
- salud de [Repo Engine](https://github.com/DannyBaanks/repo-engine): si los hooks de la
  compuerta de publicación existen, se ejecutan y qué dirían de lo pendiente de subir.

## Instalar

```sh
./install.sh        # corre los gates; si pasan, instala en ~/.local/bin y activa los timers
```

Requisitos: Linux con `systemd --user`, `git`, `bash`, `python3`, `flock`, `timeout`.
Opcionales: `notify-send` (avisos), `gh` (distinguir 404 de falta de permisos).

## Uso

```sh
git-autosync status [--all]     # resultado de la última corrida
git-autosync log [N] [--all]    # historial de cambios de estado
git-autosync --dry-run          # solo observa (ls-remote): no escribe nada
git-autosync report             # el reporte de arriba
git-autosync archive <Carpeta>  # remoto borrado a propósito (p.ej. hackathon terminado)
```

## Configuración (`~/.config/git-autosync/`, una entrada por línea)

| Archivo | Para qué |
|---|---|
| `roots` | carpetas a vigilar (por defecto la del autor: `~/Development/ISyCo Git`) |
| `exclude` | globs de carpetas a ignorar |
| `pin` | repos donde solo se hace fetch |
| `allow-busy` | repos cuyo checkout puede avanzar aunque un proceso lo use |
| `archived` | repos cuyo remoto borraste a propósito |
| `pr-flow` | repos que integran por PR (si no existe, se deduce del historial) |
| `repo-engine` | ruta a `repo-engine.py` (por defecto la del autor) |

## Detener y desinstalar

```sh
systemctl --user disable --now git-autosync.timer git-autosync-report.timer
rm ~/.local/bin/git-autosync ~/.local/bin/git-autosync-report
```

Ningún paso toca tus repositorios.

## Pruebas

`tests/gates.sh` crea repos y remotos temporales y prueba, con commits reales: fast-forward
seguro, DENY ante cambios rastreados, archivos que chocarían (incluso ignorados), ramas
feature, worktrees ocupados, commits locales, divergencia, force-push remoto, dos corridas
simultáneas, commits y ediciones que aparecen a mitad de corrida (con pausas
deterministas), locks de git, SIGTERM y SIGKILL a mitad de un fast-forward, hooks del repo,
autostash, refspecs tipo mirror, rutas con espacios y Unicode, dry-run sin ninguna
escritura, idempotencia y el reporte de solo lectura.

## Límites conocidos

- Un proceso que edita un archivo sin tenerlo como cwd ni en sus argumentos no se detecta.
- Un servicio que corre desde un checkout no se reinicia: el reporte avisa, tú decides.
- Un fast-forward cortado por SIGKILL o corte de luz deja el repo en `INTERRUPTED` (archivos
  mezclados entre el commit viejo y el nuevo; tu trabajo no estaba en juego porque el árbol
  estaba limpio) y no se toca hasta que lo revises.
