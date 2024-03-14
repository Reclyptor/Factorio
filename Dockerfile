FROM alpine:latest

ARG GLIBC_VERSION=2.28-r0
ARG FACTORIO_SHA256=8e13353ab23d57989db7b06594411d30885de1a923f3a989d12749c1abc01583
ENV FACTORIO_VERSION=1.1.104

RUN apk --no-cache add ca-certificates openssl wget

RUN                                                                                                                                            \
  wget -q -O "/etc/apk/keys/sgerrand.rsa.pub" "https://alpine-pkgs.sgerrand.com/sgerrand.rsa.pub"                                              \
  && wget "https://github.com/sgerrand/alpine-pkg-glibc/releases/download/${GLIBC_VERSION}/glibc-${GLIBC_VERSION}.apk"                         \
  && apk add --force-overwrite "glibc-${GLIBC_VERSION}.apk"

RUN                                                                                                                                            \
   wget -q -O "/tmp/factorio_headless_x64_${FACTORIO_VERSION}.tar.xz" "https://factorio.com/get-download/${FACTORIO_VERSION}/headless/linux64" \
   && echo "${FACTORIO_SHA256} /tmp/factorio_headless_x64_${FACTORIO_VERSION}.tar.xz" | sha256sum -c                                           \
   && tar -xv -C /opt -f "/tmp/factorio_headless_x64_${FACTORIO_VERSION}.tar.xz"                                                               \
   && rm "/tmp/factorio_headless_x64_${FACTORIO_VERSION}.tar.xz"

RUN apk --no-cache del ca-certificates openssl wget

VOLUME ["/opt/factorio/saves", "/opt/factorio/mods", "/opt/factorio/map-gen-settings.json"]

WORKDIR /opt/factorio/saves

EXPOSE "34197/udp"
EXPOSE "27015/tcp"

COPY entry.sh /bin/entry.sh

RUN chmod +x /bin/entry.sh

ENTRYPOINT ["/bin/entry.sh"]
