FROM alpine:latest

# Install required packages
RUN apk add --no-cache \
    curl \
    iproute2 \
    sudo \
    bash

# Create hairpin user
RUN adduser -D -s /bin/bash hairpin && \
    echo "hairpin:hairpin" | chpasswd

# Copy sudoers configuration
COPY hairpin-sudoers /etc/sudoers.d/hairpin
RUN chmod 440 /etc/sudoers.d/hairpin

# Copy hairpin script
COPY hairpin.sh /usr/local/bin/hairpin
RUN chmod +x /usr/local/bin/hairpin

# Create necessary directories with proper permissions
RUN mkdir -p /tmp && chmod 1777 /tmp

# Switch to hairpin user
USER hairpin
WORKDIR /home/hairpin

# Set up environment
ENV PATH="/usr/local/bin:$PATH"

# Default command
CMD ["hairpin", "--help"]
