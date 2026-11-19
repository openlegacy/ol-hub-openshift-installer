#!/usr/bin/env bash
# One-time carry-over of an app's files from the container filesystem to the volume a newer installer gives it.
#
# An app that gets a volume in a later installer version (ol-integration: its tenant artifacts, APP_CARRY in
# common.sh) kept those files in the container's writable layer until then. The Helm upgrade that adds the
# volume replaces the pod, and the new pod mounts the empty volume over those paths - the files would be lost.
# So, when the app's Deployment still runs without the "data" volume:
#   carry_out  before the upgrade: copy the paths out of the running pod into generated/carry/<app>
#              (mode 700 - the files are tenant data) and leave generated/carry/<app>.pending
#   carry_in   after the upgrade: copy them into the new pod - now onto the volume - and check the file count;
#              runs whenever the .pending marker exists, so an interrupted run is finished by the next one
# File by file with cat: the images have no tar (so no kubectl cp), only bash and coreutils.

carry_needed() {   # carry_needed <app> -> 0 when the app has APP_CARRY paths and its Deployment lacks the volume
  local a=$1 vols
  [[ -n "${APP_CARRY[$a]:-}" && "$DRY_RUN" != true ]] || return 1
  vols=$(kube -n "$NAMESPACE" get deploy "$a" -o jsonpath='{.spec.template.spec.volumes[*].name}' 2>/dev/null) || return 1
  [[ " $vols " != *" data "* ]]
}

carry_out() {   # carry_out <app>: the running pod's APP_CARRY paths -> generated/carry/<app>
  local a=$1 dir="$GEN/carry/$1" pod f n=0
  pod=$(kube -n "$NAMESPACE" get pods -l "app=$a" --field-selector=status.phase=Running \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [[ -n "$pod" ]] || { warn "$a: no running pod - nothing to carry over to its new volume"; return 0; }
  mkdir -p "$dir"; chmod 700 "$GEN/carry" "$dir"
  info "$a: copying ${APP_CARRY[$a]} out of pod $pod before it gets its volume"
  while IFS= read -r -d '' f; do
    mkdir -p "$dir$(dirname "$f")"
    kube -n "$NAMESPACE" exec "$pod" -c "$a" -- cat -- "$f" > "$dir$f" \
      || die "$a: could not copy $f out of pod $pod - nothing was changed; re-run"
    n=$((n + 1))
  done < <(kube -n "$NAMESPACE" exec "$pod" -c "$a" -- bash -c \
             'shopt -s globstar dotglob nullglob
              for d in "$@"; do for f in "$d"/**; do [[ -f $f && ! -L $f ]] && printf "%s\0" "$f"; done; done; true' \
             _ ${APP_CARRY[$a]})
  if (( n == 0 )); then info "$a: no files to carry over"; return 0; fi
  echo "$n" > "$dir.pending"
  ok "$a: $n file(s), $(du -sh "$dir" | cut -f1), kept in $dir until they are on the volume"
}

carry_in() {   # carry_in <app>: generated/carry/<app> -> the new pod (onto its volume), when .pending exists
  local a=$1 dir="$GEN/carry/$1" f rel n=0 want got
  [[ -f "$dir.pending" ]] || return 0
  want=$(cat "$dir.pending")
  info "$a: copying $want carried-over file(s) onto its volume"
  while IFS= read -r -d '' f; do
    rel=${f#"$dir"}
    kube -n "$NAMESPACE" exec -i "deploy/$a" -c "$a" -- bash -c 'mkdir -p -- "$(dirname -- "$1")" && cat > "$1"' _ "$rel" < "$f" \
      || die "$a: could not copy $rel into the new pod - the files stay in $dir; re-run ./install.sh to retry"
    n=$((n + 1))
  done < <(find "$dir" -type f -print0)
  got=$(kube -n "$NAMESPACE" exec "deploy/$a" -c "$a" -- bash -c \
          'shopt -s globstar dotglob nullglob; n=0
           for d in "$@"; do for f in "$d"/**; do [[ -f $f && ! -L $f ]] && n=$((n + 1)); done; done; echo $n' \
          _ ${APP_CARRY[$a]} || echo 0)
  (( n == want && got >= want )) \
    || die "$a: carried $want file(s), copied $n, the volume has $got - the files stay in $dir; re-run ./install.sh"
  [[ "$dir" == "$ROOT"/generated/carry/?* ]] && rm -rf -- "$dir" "$dir.pending"
  ok "$a: $n file(s) carried over onto its volume"
}
