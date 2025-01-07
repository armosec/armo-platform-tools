# ---------------------------------------
# 1) Build stage
# ---------------------------------------
    FROM golang:1.20 AS builder

    WORKDIR /app
    COPY go.mod go.sum ./
    RUN go mod download
    
    COPY cmd/ cmd/
    RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o sizing-checker cmd/main.go
    
    # ---------------------------------------
    # 2) Final minimal image
    # ---------------------------------------
    FROM alpine:3.18
    RUN apk --no-cache add ca-certificates
    
    # Add non-root user (optional best-practice)
    RUN adduser -D -g '' appuser
    
    WORKDIR /home/appuser
    COPY --from=builder /app/sizing-checker ./sizing-checker
    USER appuser
    
    EXPOSE 8080
    ENTRYPOINT ["./sizing-checker"]