#https://developer.ibm.com/tutorials/awb-quantum-safe-openssl/
FROM ubuntu:22.04
# Step 1. Install the dependencies
RUN apt update
RUN apt -y install git build-essential perl cmake autoconf libtool zlib1g-dev
RUN mkdir /quanutmsafe
# set this to a working dir of your choice
ENV WORKSPACE=/quantumsafe 
# this will contain all the build artifacts
ENV BUILD_DIR=$WORKSPACE/build 
RUN mkdir -p $BUILD_DIR/lib64
RUN ln -s $BUILD_DIR/lib64 $BUILD_DIR/lib

# Step 2. Install OpenSSL
WORKDIR $WORKSPACE
COPY *proxy.crt /usr/local/share/ca-certificates/proxy.crt
RUN chmod 644 /usr/local/share/ca-certificates/proxy.crt && update-ca-certificates; exit 0
RUN git clone https://github.com/openssl/openssl.git
WORKDIR openssl
# Directory given with --prefix MUST be absolute hence quantumsafe created at root
RUN ./Configure --prefix=$BUILD_DIR no-ssl no-tls1 no-tls1_1 no-afalgeng no-shared threads -lm
RUN make -j $(nproc)
RUN make -j $(nproc) install_sw install_ssldirs

# Step 3 Step 3. Install liboqs
WORKDIR $WORKSPACE

RUN git clone https://github.com/open-quantum-safe/liboqs.git
WORKDIR liboqs

RUN mkdir build 
WORKDIR build

RUN cmake \
  -DCMAKE_INSTALL_PREFIX=$BUILD_DIR \
  -DBUILD_SHARED_LIBS=ON \
  -DOQS_USE_OPENSSL=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DOQS_BUILD_ONLY_LIB=ON \
  -DOQS_DIST_BUILD=ON \
  ..

RUN make -j $(nproc)
RUN make -j $(nproc) install

# Step 4. Install Open Quantum Safe provider for OpenSSL 3
WORKDIR $WORKSPACE

RUN git clone https://github.com/open-quantum-safe/oqs-provider.git
WORKDIR oqs-provider



ENV liboqs_DIR=$BUILD_DIR 
RUN cmake -DCMAKE_INSTALL_PREFIX=$WORKSPACE/oqs-provider -DOPENSSL_ROOT_DIR=$BUILD_DIR -DCMAKE_BUILD_TYPE=Release -S . -B _build
RUN cmake --build _build

# Manually copy the lib files into the build dir
RUN cp _build/lib/* $BUILD_DIR/lib/

# We need to edit the openssl config to use the oqsprovider
RUN sed -i "s/default = default_sect/default = default_sect\noqsprovider = oqsprovider_sect/g" $BUILD_DIR/ssl/openssl.cnf
RUN sed -i "s/\[default_sect\]/\[default_sect\]\nactivate = 1\n\[oqsprovider_sect\]\nactivate = 1\n/g" $BUILD_DIR/ssl/openssl.cnf

ENV OPENSSL_CONF=$BUILD_DIR/ssl/openssl.cnf
ENV OPENSSL_MODULES=$BUILD_DIR/lib
RUN $BUILD_DIR/bin/openssl list -providers -verbose -provider oqsprovider

# Step 5. Install and run cURL with quantum-safe algorithms

WORKDIR $WORKSPACE

RUN git clone https://github.com/curl/curl.git
WORKDIR curl


RUN autoreconf -fi
RUN ./configure \
  LIBS="-lssl -lcrypto -lz" \
  LDFLAGS="-Wl,-rpath,$BUILD_DIR/lib64 -L$BUILD_DIR/lib64 -Wl,-rpath,$BUILD_DIR/lib -L$BUILD_DIR/lib -Wl,-rpath,/lib64 -L/lib64 -Wl,-rpath,/lib -L/lib" \
  CFLAGS="-O3 -fPIC" \
  --prefix=$BUILD_DIR \
  --with-ssl=$BUILD_DIR \
  --with-zlib=/ \
  --enable-optimize --enable-libcurl-option --enable-libgcc --enable-shared \
  --enable-ldap=no --enable-ipv6 --enable-versioned-symbols \
  --disable-manual \
  --without-default-ssl-backend \
  --without-librtmp --without-libidn2 \
  --without-gnutls --without-mbedtls \
  --without-wolfssl --without-libpsl

RUN make -j $(nproc)
RUN make -j $(nproc) install

# https://developer.ibm.com/tutorials/awb-building-quantum-safe-web-applications/

# Step 3. Create self-signed keys and certificates using quantum-safe algorithms (on Apache HTTPD server)
WORKDIR $WORKSPACE
# ADD CA.crt $WORKSPACE/CA.crt
RUN $BUILD_DIR/bin/openssl req -addext basicConstraints=critical,CA:TRUE -x509 -new -keyout CA.key -out CA.crt -nodes -subj "/CN=oqstest CA" -days 365 -config $BUILD_DIR/ssl/openssl.cnf

RUN $BUILD_DIR/bin/openssl req -addext subjectAltName=DNS:localhost -new -keyout server.key -out server.csr -nodes -subj "/CN=localhost" -config $BUILD_DIR/ssl/openssl.cnf
RUN $BUILD_DIR/bin/openssl x509 -req -copy_extensions copy -in server.csr -out server.crt -CA CA.crt -CAkey CA.key -CAcreateserial -days 365
RUN cat server.crt > qsc-ca-chain.crt
RUN cat CA.crt >> qsc-ca-chain.crt
CMD $BUILD_DIR/bin/openssl s_server -cert $WORKSPACE/server.crt -key $WORKSPACE/server.key -www -tls1_3 -CAfile $WORKSPACE/CA.crt -curves kyber768:x25519_kyber768 -trace
