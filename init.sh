#!/bin/bash
set -e

# =================================================================
# 1. Configure Real-Time User Permissions and Limits
# =================================================================
echo "[1/10] Configuring real-time user limits..."
USER="ubuntu"  # Change if different
id -nG "$USER" | grep -qw "audio" || usermod -aG audio $USER

# Only create if doesn't exist or content is different
if [ ! -f /etc/security/limits.d/audio.conf ] || ! grep -q "rtprio 99" /etc/security/limits.d/audio.conf; then
    cat <<EOF | tee /etc/security/limits.d/audio.conf
@audio - rtprio 99
@audio - memlock unlimited
@audio - nice -20
EOF
fi

# =================================================================
# 2. CPU Isolation and Kernel Tuning (Persistent)
# =================================================================
echo "[2/10] Tuning kernel and CPU isolation..."

# Modify /boot/uEnv.txt for ARMBIAN
BOOT_FILE="/boot/uEnv.txt"
ISOL_FLAGS="isolcpus=1-3 nohz_full=1-3 rcu_nocbs=1-3 threadirqs"
RT_FLAGS="preempt=full nmi_watchdog=0 nosoftlockup"
AUDIO_FLAGS="threadirqs irqaffinity=0"

# First remove any existing isolation flags to prevent duplication
sed -i -E 's/(isolcpus|nohz_full|rcu_nocbs|threadirqs|mitigations|preempt|nmi_watchdog|nosoftlockup|irqaffinity)[^ ]* //g' "$BOOT_FILE"

if ! grep -q "$ISOL_FLAGS $RT_FLAGS $AUDIO_FLAGS" "$BOOT_FILE"; then
    if grep -q "^APPEND=" "$BOOT_FILE"; then
        sed -i "s|^APPEND=\(.*\)|APPEND=\1 $ISOL_FLAGS $RT_FLAGS $AUDIO_FLAGS|" "$BOOT_FILE"
    else
        echo "APPEND=$ISOL_FLAGS $RT_FLAGS $AUDIO_FLAGS" >> "$BOOT_FILE"
    fi
fi

# =================================================================
# 3. System Tuning
# =================================================================
echo "[3/10] Configuring system parameters..."

# Create sysctl configuration file for audio optimizations
cat <<EOF | tee /etc/sysctl.d/99-audio-optimizations.conf
# Virtual memory settings
vm.dirty_ratio = 60
vm.dirty_background_ratio = 30

# Real-time scheduling settings
kernel.sched_rt_runtime_us = -1
kernel.sched_rt_period_us = 1000000

# Network optimizations for reduced latency
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_low_latency = 1

# File system optimizations
fs.inotify.max_user_watches = 524288
EOF

# Apply sysctl settings
sysctl -p /etc/sysctl.d/99-audio-optimizations.conf

# =================================================================
# 4. CPU Governor Configuration
# =================================================================
echo "[4/10] Configuring CPU governor..."

# Create systemd unit for CPU governor configuration
cat <<EOF | tee /etc/systemd/system/cpu-governor.service
[Unit]
Description=CPU Governor Configuration
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for cpu in /sys/devices/system/cpu/cpu[0-9]*; do echo performance > \$cpu/cpufreq/scaling_governor; done'

[Install]
WantedBy=multi-user.target
EOF

# Enable the service
systemctl enable cpu-governor.service

# Set governor immediately
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    echo performance > $cpu/cpufreq/scaling_governor 2>/dev/null || true
done

# =================================================================
# 5. Install Packages
# =================================================================
echo "[5/10] Installing packages..."
PACKAGES="jackd2 qjackctl fluidsynth alsa-utils irqbalance tuned-utils"
for pkg in $PACKAGES; do
    if ! dpkg -l | grep -q "^ii.*$pkg"; then
        apt-get update
        apt-get install -y $PACKAGES
        break
    fi
done

# =================================================================
# 6. ALSA/JACK Configuration
# =================================================================
echo "[6/10] Configuring audio subsystems..."
if [ ! -f /etc/modules-load.d/snd-seq.conf ] || ! grep -q "snd-seq" /etc/modules-load.d/snd-seq.conf; then
    echo "snd-seq" | tee /etc/modules-load.d/snd-seq.conf
fi

# Create CPU-pinned JACK startup script
cat <<EOF | tee /home/$USER/start_jack.sh
#!/bin/bash
export JACK_NO_AUDIO_RESERVATION=1
taskset -c 1-3 jackd -d alsa -d hw:P230Q200
EOF
chmod +x /home/$USER/start_jack.sh
chown $USER:$USER /home/$USER/start_jack.sh

# =================================================================
# 7. Systemd Services with CPU Pinning
# =================================================================
echo "[7/10] Configuring services..."

# JACK Service
cat <<EOF | tee /etc/systemd/system/jack.service
[Unit]
Description=JACK Audio Server
After=sound.target

[Service]
User=$USER
Environment=JACK_NO_AUDIO_RESERVATION=1
ExecStart=/home/$USER/start_jack.sh
Restart=always
RestartSec=5
CPUAffinity=1,2,3
CPUSchedulingPolicy=fifo
CPUSchedulingPriority=95
Nice=-20

[Install]
WantedBy=multi-user.target
EOF

# FluidSynth Service
cat <<EOF | tee /etc/systemd/system/fluidsynth.service
[Unit]
Description=FluidSynth JACK Service
After=jack.service

[Service]
User=$USER
ExecStart=/bin/sh -c 'taskset -c 1-3 fluidsynth -i -g 4 -d -j -s -p 9800 -C0 -R0 -l -a jack -m alsa_seq "/usr/share/sounds/sf2/default-GM.sf2"'
Restart=always
RestartSec=5
CPUAffinity=1,2,3
CPUSchedulingPolicy=fifo
CPUSchedulingPriority=90
Nice=-20

[Install]
WantedBy=multi-user.target
EOF

# =================================================================
# 8. IRQ Tuning
# =================================================================
echo "[8/10] Tuning IRQ affinity..."
for irq in $(awk '/^[0-9]+:/ {print $1}' /proc/interrupts | tr -d :); do
    current_affinity=$(cat /proc/irq/$irq/smp_affinity_list 2>/dev/null || echo "")
    if [ "$current_affinity" != "0" ]; then
        echo 0 > /proc/irq/$irq/smp_affinity_list 2>/dev/null || true
    fi
done

# =================================================================
# 9. Configure tuned profile for low-latency
# =================================================================
echo "[9/10] Configuring tuned profile..."
if ! dpkg -l | grep -q "tuned"; then
    apt-get install -y tuned
fi

mkdir -p /etc/tuned/audio-lowlatency
cat <<EOF | tee /etc/tuned/audio-lowlatency/tuned.conf
[main]
include=latency-performance

[cpu]
force_latency=1
governor=performance
energy_perf_bias=performance
min_perf_pct=100

[vm]
transparent_hugepages=never

[sysctl]
kernel.timer_migration=0
kernel.sched_rt_runtime_us=-1
EOF

systemctl enable --now tuned
tuned-adm profile audio-lowlatency

# =================================================================
# 10. Enable Services
# =================================================================
echo "[10/10] Enabling services..."
systemctl daemon-reload
systemctl enable jack
systemctl enable fluidsynth
systemctl enable audio-connections

echo "Done! Reboot required."
echo "Verify with:"
echo "  ps -eo pid,comm,psr | grep -E 'jackd|fluidsynth'"
# realtime kernel install
echo "armbian-update -k 6.6.77 -r utajum/amlogic-s9xxx-armbian"
echo "taskset -c 1-3 cyclictest -t -m -p99 -D 1h --affinity=1-3"