FROM alpine:3.19
RUN apk add --no-cache wireguard-tools iproute2 kmod
COPY raspi/wireguard/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
