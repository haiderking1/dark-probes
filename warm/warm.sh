#!/bin/bash
# warm/warm.sh: a warm runner (warm.yml). windows boots once and stays up;
# every few seconds the wjob-* branches tools/cloudrun.sh pushes are looked
# at, one is claimed (a claim-* branch made only if it isn't there: two
# runners never take the same job), its programs run, and their outputs go
# back as a done-* branch (out/warm/: NAME[.e].out, codes.txt, errors.txt).
# Stops when nothing came for IDLE seconds, or when the job's time is near
set -u
idle=${IDLE:-2700}
until=$((SECONDS + ${HOURS_SECONDS:-20400}))

boot () {
  if [ -n "${QEMU:-}" ]; then
    kill "$QEMU" "$TPM" 2>/dev/null || true
    wait "$QEMU" 2>/dev/null || true
  fi
  rm -f tpm.sock
  swtpm socket --tpmstate dir=img/tpm --ctrl type=unixio,path=tpm.sock --tpm2 --pid file=tpm.pid --daemon
  TPM=$(cat tpm.pid)
  cp img/vars.fd vars-run.fd
  qemu-system-x86_64 -accel kvm -machine q35 -cpu host -smp 4 -m 8192 \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file=vars-run.fd \
    -chardev socket,id=chrtpm,path=tpm.sock -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0 \
    -device ahci,id=ahci -drive file=img/win.qcow2,if=none,id=disk0,snapshot=on -device ide-hd,drive=disk0,bus=ahci.0 \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:7777-:7777,hostfwd=tcp:127.0.0.1:7778-:7778 -device e1000e,netdev=n0 \
    -audiodev none,id=snd0 -device ich9-intel-hda -device hda-duplex,audiodev=snd0 \
    -vga std -display none &
  QEMU=$!
  up 900 || { echo "runner never answered"; exit 1; }
  echo "windows up at $SECONDS s"
}

# up SECS: the probe runner answers both ports within SECS
up () {
  local end=$((SECONDS + $1))
  until python3 image/winrun.py 7777 img/token 60000 warm.out probes/ref_crypttime/ref_crypttime.exe > /dev/null 2>&1 &&
        python3 image/winrun.py 7778 img/token 60000 warm.out probes/ref_crypttime/ref_crypttime.exe > /dev/null 2>&1; do
    [ $SECONDS -lt $end ] || return 1
    sleep 5
  done
}

# run JOB: a claimed job's programs, the outputs pushed as done-JOB
run () {
  local job=$1 dir=work/$1
  rm -rf "$dir" && mkdir -p "$dir/out/warm"
  git fetch -q --depth 1 origin "refs/heads/$job" || return 1
  git archive FETCH_HEAD job | tar -x -C "$dir"
  local out=$dir/out/warm
  while read -r name port deadline; do
    files=$(sed -n 's|^|'"$dir"'/job/'"$name"'/|p' "$dir/job/$name/order.txt")
    suffix=$([ "$port" = 7778 ] && echo .e || true)
    echo "== $name$suffix" >> "$out/errors.txt"
    # shellcheck disable=SC2086 # the files split
    timeout $((deadline / 1000 + 60)) python3 image/winrun.py "$port" img/token "$deadline" "$out/$name$suffix.out" $files \
      >> "$out/codes.txt" 2>> "$out/errors.txt" \
      || { echo "$name$suffix failed" >> "$out/codes.txt"; up 60 || { echo "runner gone after $name, booting again"; boot; }; }
  done < "$dir/job/list.txt"
  local index
  index=$(mktemp -u)  # a path only: git won't take an empty file as an index
  GIT_INDEX_FILE=$index git --work-tree="$dir" add out
  local tree commit
  tree=$(GIT_INDEX_FILE=$index git write-tree)
  commit=$(git commit-tree "$tree" -m "done: $job")
  rm -f "$index"
  git push -q origin "$commit:refs/heads/done-$job"
  echo "$job done at $SECONDS s"
}

export GIT_AUTHOR_NAME=warm GIT_AUTHOR_EMAIL=warm@localhost GIT_COMMITTER_NAME=warm GIT_COMMITTER_EMAIL=warm@localhost
boot
last=$SECONDS
while [ $((SECONDS - last)) -lt "$idle" ] && [ $SECONDS -lt "$until" ]; do
  refs=$(git ls-remote origin 'refs/heads/wjob-*' 'refs/heads/claim-wjob-*' 2>/dev/null)
  job=$(echo "$refs" | awk '{ sub("refs/heads/", "", $2); print $2 }' | sort |
        awk '/^claim-/ { sub("^claim-", ""); claimed[$0] = 1; next } { jobs[++n] = $0 } END { for (i = 1; i <= n; i++) if (!claimed[jobs[i]]) { print jobs[i]; exit } }')
  if [ -n "$job" ] && git push -q --force-with-lease="refs/heads/claim-$job:" origin "HEAD:refs/heads/claim-$job" 2>/dev/null; then
    echo "$job claimed at $SECONDS s"
    run "$job" || echo "$job couldn't be fetched"
    last=$SECONDS
  else
    sleep 5
  fi
done
echo "stopping at $SECONDS s"
