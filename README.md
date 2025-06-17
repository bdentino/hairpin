# Hairpin NAT Route Manager

A utility daemon that polls for external IPv4/IPv6 addresses and creates local routes to mitigate hairpin NAT routing issues.

> **Caveat:**
> This script is only useful in network configurations where all outbound traffic from the system to its own external IP is expected to be routed back to the same system.
> If you are behind a router that forwards different ports to different devices, this script may not work as expected and could interfere with your network setup. For example, if you have port forwarding rules at your router that send port 8080 to device A and port 9090 to device B and you are trying to access device B from device A using their shared public IP, this script will prevent you from accessing device B.

## Features

- Polls external IPv4 and/or IPv6 addresses
- Creates host routes on the loopback interface for detected IPs
- DNS64 prefix support for IPv4-to-IPv6 mapping
- Automatic cleanup on IP changes and daemon shutdown
- Configurable polling interval
- Docker support with non-root execution

## Usage

### Basic Usage

```bash
# Enable IPv4 monitoring
./hairpin.sh --ipv4

# Enable IPv6 monitoring
./hairpin.sh --ipv6

# Enable both IPv4 and IPv6
./hairpin.sh --ipv4 --ipv6

# Add DNS64 prefix support (requires --ipv4)
./hairpin.sh --ipv4 --dns64 64:ff9b::

# Custom polling interval (default: 60 seconds)
./hairpin.sh --ipv4 --ipv6 --interval 30
```

### Options

- `--ipv4`: Enable IPv4 polling and route creation
- `--ipv6`: Enable IPv6 polling and route creation
- `--dns64 PREFIX`: Create additional IPv6 route using DNS64 prefix (requires --ipv4)
- `--interval SECONDS`: Polling interval in seconds (default: 60)
- `--help`: Show help message

## Installation

### Prerequisites

The script requires sudo privileges for route manipulation. Install the sudoers configuration:

```bash
sudo cp hairpin-sudoers /etc/sudoers.d/hairpin
sudo chmod 440 /etc/sudoers.d/hairpin
```

### Direct Installation

```bash
# Make script executable
chmod +x hairpin.sh

# Run directly
./hairpin.sh --ipv4 --ipv6
```

### Docker Installation

```bash
# Build the container
docker-compose build

# Run with IPv4 only
docker-compose up hairpin-ipv4

# Run with IPv6 only
docker-compose up hairpin-ipv6

# Run with both IPv4/IPv6 and DNS64
docker-compose up hairpin-full

# Development container (keeps running for testing)
docker-compose up hairpin
```

## How It Works

1. **IP Detection**: Polls external IP services (ipify.org) to detect current public IPs
2. **Route Management**: Creates host routes (`/32` for IPv4, `/128` for IPv6) on the loopback interface
3. **DNS64 Support**: When enabled, creates an additional IPv6 route by combining the DNS64 prefix with the detected IPv4 address
4. **Change Detection**: Monitors for IP changes and updates routes accordingly
5. **Cleanup**: Removes all created routes on shutdown or IP changes

### DNS64 Example

With `--dns64 64:ff9b::` and detected IPv4 `203.0.113.1`:

- Creates route for `203.0.113.1/32`
- Creates additional route for `64:ff9b::cb00:7101/128` (DNS64 mapped address)

## State Management

The daemon maintains minimal state:

- `/tmp/hairpin.sh.lock`: Process lock file
- Routes are tagged with `proto static metric 99` for automatic discovery

## Signal Handling

- `SIGTERM/SIGINT`: Graceful shutdown with route cleanup
- The daemon automatically removes all routes it created before exiting

## Network Requirements

- Outbound HTTPS access to IP detection services
- `NET_ADMIN` capability for route manipulation (when using Docker)
- IPv6 support enabled (for IPv6 functionality)

## Testing

Use the provided Docker Compose services to test different configurations:

```bash
# Test IPv4 functionality
docker-compose up hairpin

# Check routes (from another terminal)
docker exec hairpin ip route show dev lo

# Test cleanup
docker-compose down
```

## Troubleshooting

### Permission Errors

Ensure the sudoers file is properly installed and the user is in the sudoers configuration.

### IPv6 Issues

Verify IPv6 is enabled on the system:

```bash
sysctl net.ipv6.conf.all.disable_ipv6
```

### Route Conflicts

The script will fail if routes already exist. Clean existing routes manually if needed:

```bash
sudo ip route del <IP>/32 dev lo  # IPv4
sudo ip route del <IP>/128 dev lo # IPv6
```
