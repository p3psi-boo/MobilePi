set dotenv-load := true
set shell := ["bash", "-uc"]

web_host := env_var_or_default("MOBILEPI_WEB_HOST", "127.0.0.1")
web_port := env_var_or_default("MOBILEPI_WEB_PORT", "8082")
hub_url := env_var_or_default("MOBILEPI_HUB_WS_URL", "ws://localhost:8080/ws")
hub_port := env_var_or_default("MOBILEPI_HUB_PORT", "8080")
tenant_key := env_var_or_default("MOBILEPI_TENANT_KEY", "")

default:
    @just --list

# Start the MobilePi Hub server.
hub:
    cd hub && MOBILEPI_TENANT_KEY="{{tenant_key}}" dart run bin/hub.dart {{hub_port}}

# Start the local Daemon and register it with Hub.
daemon:
    cd node && MOBILEPI_TENANT_KEY="{{tenant_key}}" dart run bin/node.dart {{hub_url}}

# Start the Flutter web client through flutter run -d web-server.
client-web:
    cd client && flutter run -d web-server --web-hostname={{web_host}} --web-port={{web_port}}

# Start the Flutter client on a specific device, default web-server.
client device="web-server":
    if [ "{{device}}" = "web-server" ]; then \
      cd client && flutter run -d web-server --web-hostname={{web_host}} --web-port={{web_port}}; \
    else \
      cd client && flutter run -d "{{device}}"; \
    fi

# Build the Flutter Android release APK for arm64-v8a devices.
android-arm64:
    cd client && flutter build apk --release --split-per-abi
    @echo "Built client/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"

# Print the commands normally used during local web development.
dev:
    @echo "Run these in separate terminals:"
    @echo "  just hub"
    @echo "  just daemon"
    @echo "  just client-web"
