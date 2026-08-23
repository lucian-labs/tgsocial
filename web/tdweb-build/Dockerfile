# Builds tdweb (TDLib compiled to WebAssembly) from TDLib source, so the web
# client ships a wasm we compiled ourselves instead of an unaudited registry
# binary. Output: /out/dist (tdweb.js + worker chunks + .wasm).
#
#   docker build -t tdweb-build web/tdweb-build
#   docker run --rm -v "$PWD/web/vendor/tdweb:/out" tdweb-build
#
# emsdk 3.1.1 is pinned because td/example/web/build-tdlib.sh checks for it.
FROM emscripten/emsdk:3.1.1
ARG TD_REF=master
RUN apt-get update && apt-get install -y --no-install-recommends gperf php-cli git cmake ninja-build && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone --depth 1 --branch ${TD_REF} https://github.com/tdlib/td.git
WORKDIR /src/td/example/web
# The scripts expect the emsdk env to be sourced and use nproc.
RUN ./build-openssl.sh
RUN ./build-tdlib.sh
RUN ./copy-tdlib.sh
RUN ./build-tdweb.sh
CMD mkdir -p /out && cp -r /src/td/example/web/tdweb/dist/. /out/ && cp /src/td/example/web/tdweb/package.json /out/package.json && cd /src/td && git rev-parse HEAD > /out/TD_COMMIT && echo "tdweb built → /out" && ls -la /out
