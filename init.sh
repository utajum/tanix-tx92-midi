#!/bin/bash
set -e

# Set USER variable at the start
USER=${SUDO_USER:-${USER:-ubuntu}}  # Use SUDO_USER if available, fallback to USER, then ubuntu

# =================================================================
# 1. Install Required Packages
# =================================================================
echo "[1/10] Installing required packages..."

AUDIO_PACKAGES="jackd2 qjackctl fluidsynth alsa-utils"

SYSTEM_PACKAGES="irqbalance tuned util-linux lm-sensors rt-tests wget telnet"

ESSENTIAL_PACKAGES="gawk sed grep coreutils procps"

PACKAGES="$AUDIO_PACKAGES $SYSTEM_PACKAGES $ESSENTIAL_PACKAGES"

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y $PACKAGES

# Download default soundfont
mkdir -p /usr/share/sounds/sf2
wget -O /usr/share/sounds/sf2/VintageDreamsWaves-v2.sf2 https://github.com/FluidSynth/fluidsynth/raw/refs/heads/master/sf2/VintageDreamsWaves-v2.sf2
chown -R $USER:$USER /usr/share/sounds/sf2

# Ensure user's home directory exists
USER_HOME=$(getent passwd "$USER" | cut -d: -f6)
if [ -z "$USER_HOME" ]; then
    echo "Error: Could not determine home directory for user $USER"
    exit 1
fi
mkdir -p "$USER_HOME"

# Create FluidSynth configuration directory and file
mkdir -p /etc/fluidsynth
cat <<EOF | tee /etc/fluidsynth/fluidsynth.conf
# Audio driver and server settings
set audio.driver jack
set audio.jack.autoconnect True
set audio.jack.multi True
#set audio.periods 16
#set audio.period-size 64
set audio.realtime-prio 90

# MIDI driver
set midi.driver alsa_seq
set midi.realtime-prio 90

# Synth settings
set synth.cpu-cores 3
set synth.midi-channels 16
set synth.polyphony 256
set synth.sample-rate 48000
set synth.gain 0.8

# Default soundfont
set synth.default-soundfont /usr/share/sounds/sf2/VintageDreamsWaves-v2.sf2

# Create a script to set up MIDI channels after FluidSynth starts
#set synth.midi-bank-select mma
set synth.verbose True

EOF

# Create channel setup script
cat <<EOF | tee "$USER_HOME/setup_channels.sh"
#!/bin/bash
# Wait for FluidSynth to start
sleep 2

# Connect to running FluidSynth instance via telnet and send commands
(
# First connect and wait for prompt
echo ""
sleep 2
# Disable channels 0-3 using Control Change commands
# CC 120 = All Sound Off
# CC 123 = All Notes Off
# CC 7 = Volume (set to 0)
for chan in 0 1 2 3; do
    sleep 1
    echo "cc \$chan 120 0"  # All Sound Off
    echo "cc \$chan 123 0"  # All Notes Off
    echo "cc \$chan 7 0"    # Volume = 0
done
for chan in 4 5 6 7 8 9 10 11 12 13 14 15; do
    sleep 1
    echo "cc \$chan 7 127"    # Volume = 0
done
# Now set up the other channels
echo "select 4 0 0 22"  # FM Bells 1
echo "select 5 0 0 0"  # FM Bells 1
echo "select 6 0 0 0"  # FM Bells 1
echo "select 7 0 0 0"  # FM Bells 1
echo "select 8 0 0 42" # Lead Synth 2
echo "select 9 0 128 0" # TR-101 Drumset
echo "select 10 0 0 0" # FM Bells 1
echo "select 11 0 0 0" # FM Bells 1
echo "select 12 0 0 0" # FM Bells 1
echo "select 13 0 0 0" # FM Bells 1
echo "select 14 0 0 0" # FM Bells 1
echo "select 15 0 0 0" # FM Bells 1
echo "quit"
) | telnet localhost 9800
EOF
chmod +x "$USER_HOME/setup_channels.sh"
chown $USER:$USER "$USER_HOME/setup_channels.sh"

# Update FluidSynth service to use the setup script
cat <<EOF | tee /etc/systemd/system/fluidsynth.service
[Unit]
Description=FluidSynth JACK Service
After=jack.service

[Service]
User=$USER
ExecStart=/bin/sh -c 'taskset -c 1-3 fluidsynth -f /etc/fluidsynth/fluidsynth.conf -i -d -j -s -p 9800 -l'
ExecStartPost=$USER_HOME/setup_channels.sh
Restart=always
RestartSec=5
CPUAffinity=1,2,3
CPUSchedulingPolicy=fifo
CPUSchedulingPriority=90
Nice=-20

[Install]
WantedBy=multi-user.target
EOF

REQUIRED_BINARIES="jackd fluidsynth taskset cyclictest sensors awk sed grep tee sysctl wget"
for binary in $REQUIRED_BINARIES; do
    if ! command -v $binary >/dev/null 2>&1; then
        echo "ERROR: Required binary '$binary' not found after package installation"
        exit 1
    fi
done

# =================================================================
# 2. Configure Real-Time User Permissions and Limits
# =================================================================
echo "[2/10] Configuring real-time user limits..."
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
# 3. CPU Isolation and Kernel Tuning (Persistent)
# =================================================================
echo "[3/10] Tuning kernel and CPU isolation..."

# Modify /boot/uEnv.txt for ARMBIAN
BOOT_FILE="/boot/uEnv.txt"
ISOL_FLAGS="isolcpus=1-3 nohz_full=1-3 rcu_nocbs=1-3 threadirqs"
RT_FLAGS="preempt=full nmi_watchdog=0 nosoftlockup"
AUDIO_FLAGS="irqaffinity=0"

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
# 4. System Tuning
# =================================================================
echo "[4/10] Configuring system parameters..."

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
# 5. CPU Governor Configuration
# =================================================================
echo "[5/10] Configuring CPU governor..."

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
# 6. ALSA/JACK Configuration
# =================================================================
echo "[6/10] Configuring audio subsystems..."
if [ ! -f /etc/modules-load.d/snd-seq.conf ] || ! grep -q "snd-seq" /etc/modules-load.d/snd-seq.conf; then
    echo "snd-seq" | tee /etc/modules-load.d/snd-seq.conf
fi

# Create CPU-pinned JACK startup script
cat <<EOF | tee "$USER_HOME/start_jack.sh"
#!/bin/bash
export JACK_NO_AUDIO_RESERVATION=1
taskset -c 1-3 jackd -d alsa -d hw:P230Q200
EOF
chmod +x "$USER_HOME/start_jack.sh"
chown $USER:$USER "$USER_HOME/start_jack.sh"

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
ExecStart=$USER_HOME/start_jack.sh
Restart=always
RestartSec=5
CPUAffinity=1,2,3
CPUSchedulingPolicy=fifo
CPUSchedulingPriority=95
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

echo "Done! Reboot required."
echo "Verify with:"
echo "  ps -eo pid,comm,psr | grep -E 'jackd|fluidsynth'"
# realtime kernel install
echo "armbian-update -k 6.12.13 -r utajum/amlogic-s9xxx-armbian"
echo "taskset -c 1-3 cyclictest -t -m -p99 -D 1h --affinity=1-3"