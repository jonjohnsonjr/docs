# Build the fortran binary that produces hello world output.
FROM cmplopes/alpine-gfortran as fortranbuilder

# Copy local code to the container image.
WORKDIR /go/src/github.com/knative/docs/helloworld
COPY . .

RUN gfortran -Wall -static helloworld.f90 -o helloworld



# Use the offical Golang image to create a bootstrap program.
# This is based on Debian and sets the GOPATH to /go.
FROM golang as gobuilder

# Copy local code to the container image.
WORKDIR /go/src/github.com/knative/docs/helloworld
COPY . .

# Build the outyet command inside the container.
# (You may fetch or manage dependencies here,
# either manually or with a tool like "godep".)
RUN CGO_ENABLED=0 GOOS=linux go build -v -o bootstrap bootstrap.go



# Use a Docker multi-stage build to create a lean production image.
# https://docs.docker.com/develop/develop-images/multistage-build/#use-multi-stage-builds
FROM alpine

# Copy the binary to the production image from the builder stage.
COPY --from=gobuilder /go/src/github.com/knative/docs/helloworld/bootstrap /bootstrap
COPY --from=fortranbuilder /go/src/github.com/knative/docs/helloworld/helloworld /helloworld

# Configure and document the service HTTP port.
ENV PORT 8080
EXPOSE $PORT

# Run the web service on container startup.
CMD ["/bootstrap"]
