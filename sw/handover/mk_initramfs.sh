#!/bin/bash
# Builds the A53's handover initramfs for stage D's D4 (docs/spec/soc.md §8.2) on the board, from the running
# Ubuntu's own files, so no package is installed: busybox (busybox-static), sshd and the libraries it loads,
# the host keys (so the laptop's known host still matches), the ubuntu user's authorized keys for root,
# uio_pdrv_genirq for this kernel, tanager-host, and sw/handover/init as /init. Nothing on the system changes.
#   sudo bash sw/handover/mk_initramfs.sh <tanager-host> <out.cpio.gz>
set -euo pipefail
[ $# -eq 2 ] || { echo "usage: $0 <tanager-host> <out.cpio.gz>" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "$0: run as root (it reads the host keys)" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
host=$1 out=$2
static() { file -L "$1" | grep -q "statically linked" || { echo "$0: $1 is not a static binary" >&2; exit 1; }; }
work=$(mktemp -d /tmp/handover-initramfs.XXXXXX)
trap 'rm -rf "$work"' EXIT
r=$work/root
mkdir -p "$r"/{bin,dev,etc/ssh,lib,proc,root/.ssh,run/sshd,sys,tmp,usr/sbin,usr/share/udhcpc}

# the programs
bb=$(command -v busybox); static "$bb"; cp "$bb" "$r/bin/busybox"
static "$host"; cp "$host" "$r/bin/tanager-host"
install -m 755 "$here/init" "$r/init"
cp /usr/sbin/sshd "$r/usr/sbin/sshd"
for l in $(ldd /usr/sbin/sshd | grep -o '/[^ ]*'); do mkdir -p "$r$(dirname "$l")"; cp -L "$l" "$r$l"; done
for l in /lib/aarch64-linux-gnu/libnss_files.so.2 /usr/lib/aarch64-linux-gnu/libnss_files.so.2; do
  [ -e "$l" ] && { mkdir -p "$r$(dirname "$l")"; cp -L "$l" "$r$l"; }
done
cp /etc/ld.so.cache "$r/etc/"   # the loader's map to the paths above

# uio_pdrv_genirq for this kernel, uncompressed for busybox's insmod
m=$(modinfo -n uio_pdrv_genirq)
case "$m" in
  *.zst) zstd -q -dc "$m" > "$r/lib/uio_pdrv_genirq.ko" ;;
  *.xz)  xz -dc "$m" > "$r/lib/uio_pdrv_genirq.ko" ;;
  *.gz)  gzip -dc "$m" > "$r/lib/uio_pdrv_genirq.ko" ;;
  *)     cp "$m" "$r/lib/uio_pdrv_genirq.ko" ;;
esac

# SSH: the system's host keys, the board session's key for root, no PAM, no passwords
cp /etc/ssh/ssh_host_*_key "$r/etc/ssh/"
chmod 600 "$r"/etc/ssh/ssh_host_*_key
cp ~ubuntu/.ssh/authorized_keys "$r/root/.ssh/authorized_keys"
chmod 700 "$r/root/.ssh"; chmod 600 "$r/root/.ssh/authorized_keys"
{
  for k in "$r"/etc/ssh/ssh_host_*_key; do echo "HostKey /etc/ssh/${k##*/}"; done
  cat <<'EOF'
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
AuthorizedKeysFile /root/.ssh/authorized_keys
StrictModes no
PidFile /run/sshd.pid
Subsystem sftp internal-sftp
EOF
} > "$r/etc/ssh/sshd_config"
printf 'root:x:0:0:root:/root:/bin/sh\nsshd:x:100:65534::/run/sshd:/bin/false\n' > "$r/etc/passwd"
printf 'root:*:19000:0:99999:7:::\nsshd:*:19000:0:99999:7:::\n' > "$r/etc/shadow"; chmod 600 "$r/etc/shadow"
printf 'root:x:0:\nnogroup:x:65534:\n' > "$r/etc/group"
printf 'passwd: files\ngroup: files\nshadow: files\n' > "$r/etc/nsswitch.conf"

# DHCP: busybox udhcpc's script
cat > "$r/usr/share/udhcpc/default.script" <<'EOF'
#!/bin/sh
case "$1" in
  deconfig) ip addr flush dev "$interface"; ip link set "$interface" up ;;
  bound|renew)
    ip addr flush dev "$interface"
    ip addr add "$ip/${mask:-24}" dev "$interface"
    [ -n "$router" ] && { ip route del default 2>/dev/null; ip route add default via "${router%% *}" dev "$interface"; }
    echo "dhcp: $interface $ip/${mask:-24} via ${router:-none}" ;;
esac
EOF
chmod 755 "$r/usr/share/udhcpc/default.script"

# the device nodes the kernel opens before /init mounts devtmpfs
mknod -m 600 "$r/dev/console" c 5 1
mknod -m 666 "$r/dev/null" c 1 3

(cd "$r" && find . | cpio -o -H newc --quiet) | gzip -9 > "$out"
ls -la "$out"; sha256sum "$out"
