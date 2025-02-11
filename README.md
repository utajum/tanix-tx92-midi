# Real-Time Audio Optimization for Tanix TX92 (Amlogic S912)

This repository contains a script for optimizing Armbian Linux for real-time audio performance on the Tanix TX92 TV Box, which features the Amlogic S912 octa-core ARM processor. The script configures the system for low-latency audio processing, making it suitable for audio applications like MIDI synthesis and audio processing.

## Prerequisites

- Tanix TX92 with Armbian installed ([Installation Guide](https://github.com/ophub/amlogic-s9xxx-armbian))
- Root access to the system
- Internet connection for package installation

## Features

- Real-time kernel parameter optimization
- CPU isolation and IRQ affinity settings
- JACK audio server configuration
- FluidSynth MIDI synthesizer setup
- System tuning for low-latency performance
- Automatic CPU governor management
- IRQ handling optimization
- Real-time scheduling configuration

## Installation

1. First, install Armbian on your Tanix TX92 following the [ophub/amlogic-s9xxx-armbian](https://github.com/ophub/amlogic-s9xxx-armbian) guide.

2. Install the real-time kernel:
   ```bash
   armbian-update -k 6.6.77 -r utajum/amlogic-s9xxx-armbian
   ```

3. Clone this repository and run the script:
   ```bash
   sudo ./init.sh
   ```

4. Reboot your system:
   ```bash
   sudo reboot
   ```

## What the Script Does

### 1. Real-Time User Configuration
- Sets up real-time privileges for audio group
- Configures user limits for real-time priority and memory locking

### 2. CPU Optimization
- Isolates CPUs 1-3 for audio processing
- Configures kernel parameters for real-time operation
- Sets up IRQ threading and affinity

### 3. System Tuning
- Optimizes virtual memory settings
- Configures real-time scheduling parameters
- Tunes network stack for low latency
- Sets up file system optimizations

### 4. Audio Stack Configuration
- Installs and configures JACK Audio Server
- Sets up FluidSynth for MIDI synthesis
- Configures CPU affinity for audio processes
- Implements systemd services with proper priorities

### 5. Performance Optimization
- Creates custom tuned profile for low-latency operation
- Manages CPU frequency scaling
- Optimizes IRQ handling
- Configures system for real-time audio processing

## Verification

After installation, you can verify the setup using:
```bash
# Check process CPU affinity
ps -eo pid,comm,psr | grep -E 'jackd|fluidsynth'

# Run latency test
taskset -c 1-3 cyclictest -t -m -p99 -D 1h --affinity=1-3
```

## Notes

- The script isolates CPUs 1-3 for audio processing, leaving CPU 0 for system tasks
- Real-time kernel is required for optimal performance
- System should be dedicated to audio processing for best results
- Some settings may need adjustment based on specific use cases

## Contributing

Feel free to submit issues, fork the repository, and create pull requests for any improvements.

## Acknowledgments

- [ophub/amlogic-s9xxx-armbian](https://github.com/ophub/amlogic-s9xxx-armbian) for the Armbian build system
- JACK Audio Connection Kit project
- FluidSynth project
- Linux real-time kernel developers 