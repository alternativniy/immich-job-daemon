FROM alpine:latest

# Add metadata labels
LABEL org.opencontainers.image.title="Immich Job Daemon"
LABEL org.opencontainers.image.description="A daemon for managing Immich job queue with priority-based execution"
LABEL org.opencontainers.image.url="https://github.com/alternativniy/immich-job-daemon"
LABEL org.opencontainers.image.source="https://github.com/alternativniy/immich-job-daemon"
LABEL org.opencontainers.image.licenses="MIT"

# Install required packages
RUN apk add --no-cache \
  curl \
  jq

# Create a non-root user to run the daemon
RUN adduser -D -u 1000 immich

# Set working directory
WORKDIR /app

# Copy the job daemon script
COPY job-daemon.sh /app/job-daemon.sh

# Make the script executable
RUN chmod +x /app/job-daemon.sh && \
  chown immich:immich /app/job-daemon.sh

# Switch to non-root user
USER immich

# Set default environment variables (can be overridden at runtime)
ENV IMMICH_URL=http://127.0.0.1:2283 \
  MAX_CONCURRENT_JOBS=1 \
  POLL_INTERVAL=10

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD pgrep -f job-daemon.sh || exit 1

# Run the daemon
CMD ["/app/job-daemon.sh"]
