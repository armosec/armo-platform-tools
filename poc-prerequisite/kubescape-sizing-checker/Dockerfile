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
    FROM alpine:3.18
    
    RUN apk --no-cache add ca-certificates
    
    # Add a non-root user (optional)
    RUN adduser -D -g '' appuser
    
    WORKDIR /home/appuser
    
    # Copy the binary from the builder stage
    COPY --from=builder /app/sizing-checker ./sizing-checker
    
    # Use the non-root user
    USER appuser
    
    ENTRYPOINT ["./sizing-checker"]
    