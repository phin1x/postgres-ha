FROM golang:1.15 as build-env

WORKDIR /workspace

COPY main.go .
COPY go.mod .
COPY go.sum .

RUN go build -o postgres-health-server main.go

FROM gcr.io/distroless/base
COPY --from=build-env /workspace/postgres-health-server /postgres-health-server
USER nonroot
CMD ["/postgres-health-server"]