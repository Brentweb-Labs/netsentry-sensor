# Bridge container - configures network bridge
FROM docker.io/library/alpine:3.19

RUN apk add --no-cache iptables iproute2 curl bash

# Create entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
