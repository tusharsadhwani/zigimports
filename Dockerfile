# Use the Microsoft container for better devcontainer integration
FROM mcr.microsoft.com/vscode/devcontainers/base:alpine

# Install required tools
RUN apk add --no-cache \
    bash \
    curl \
    git \
    build-base \
    openssl-dev \
    pkgconfig
# Install Zig from the official website
RUN curl -s https://ziglang.org/download/index.json | grep -o 'https://ziglang.org/download/[0-9.]*/zig-linux-x86_64-[0-9.]*.tar.xz' | head -n 1 | xargs curl -L -o /tmp/zig.tar.xz \
    && mkdir -p /opt/zig \
    && tar -xf /tmp/zig.tar.xz --strip-components=1 -C /opt/zig \
    && ln -s /opt/zig/zig /usr/local/bin/zig \
    && rm /tmp/zig.tar.xz
# Install ZLS, the Zig language server
RUN curl -s -LO https://builds.zigtools.org/zls-linux-x86_64-0.13.0.tar.xz && \
    mkdir -p /opt/zls && \
    tar -xf zls-linux-x86_64-0.13.0.tar.xz -C /opt/zls && \
    ln -s /opt/zls/zls /usr/local/bin/zls  && \
    rm zls-linux-x86_64-0.13.0.tar.xz
# Set environment variables
ENV PATH="/opt/zig:/opt/zls:$PATH"
