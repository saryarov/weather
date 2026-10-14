FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /out/weather ./cmd/weather

FROM alpine:3.21
COPY --from=build /out/weather /weather
EXPOSE 8080
ENTRYPOINT ["/weather"]
