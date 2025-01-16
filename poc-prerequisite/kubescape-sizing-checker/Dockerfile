# ---------------------------------------
# 1) Build stage
# ---------------------------------------
    FROM golang:1.23 AS builder

    ARG TARGETOS
    ARG TARGETARCH
    
    WORKDIR /app
    
    # 1. Copy module definitions and download dependencies
    COPY go.mod go.sum ./
    RUN go mod download
    
    # 2. Copy the source code
    COPY . .

    # 3. Build the binary with the correct OS/ARCH
    RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
        go build -o sizing-checker ./cmd
    
    # ---------------------------------------
    # 2) Final minimal image
    # ---------------------------------------
    FROM scratch
    
    COPY --from=builder /app/sizing-checker /sizing-checker
    USER 1000:1000
    WORKDIR /
    
    ENTRYPOINT ["/sizing-checker"]