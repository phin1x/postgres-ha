FROM ubuntu:20.04

RUN set -ex; \
    groupadd -g 70 postgres; \
    useradd -u 70 -r -g postgres -M -d /var/lib/postgresql -s /bin/bash postgres; \
    mkdir -p /var/lib/postgresql; \
    chown -R postgres:postgres /var/lib/postgresql

ENV LANG en_US.utf8

ARG PG_VERSION
ARG PG_MAJOR

ENV REPMGR_VERSION=v5.2.0
ARG REPMGR_VERSION

ENV PGPOOL_VERSION=V4_2_0
ARG PGPOOL_VERSION

ENV PGLOGICAL_VERSION=REL2_3_3
ARG PGLOGICAL_VERSION

ENV TIMESCALEDB_VERSION=1.7.4
ARG TIMESCALEDB_VERSION

ENV PATH $PATH:/usr/lib/postgresql/$PG_MAJOR/bin
ENV PGDATA /var/lib/postgresql/data

ENV TZ=Europe/Berlin

RUN set -ex \
        && mkdir /docker-entrypoint-initdb.d \
        && apt-mark showmanual > /tmp/aptmark \
        && apt-get update && DEBIAN_FRONTEND="noninteractive" apt-get install -y --no-install-recommends \
                wget \
               gcc \
               make \
                automake \
                autoconf \
               cmake \
               dpkg-dev \
                libtool \
                libunwind-dev \
		ca-certificates \
               bison \
               flex \
               libedit-dev \
               libxml2-dev \
               libxslt-dev \
               llvm-dev \
               clang \
               libssl-dev \
               libipc-run-perl \
               python3-dev \
               zlib1g-dev \
               libicu-dev \
#              libpam0g-dev \
               pkg-config \
               uuid-dev \
               gettext \
               gosu \
               locales \
		dnsutils  \
		xinetd \
#              krb5-dev \
#              tcl-dev \
#              openldap-dev \
#              perl-dev \
        \
        && locale-gen en_US.UTF-8 \
        \
        && wget -O /tmp/postgresql.tar.gz "https://ftp.postgresql.org/pub/source/v$PG_VERSION/postgresql-$PG_VERSION.tar.gz" \
        && mkdir -p /usr/src/postgresql \
        && tar \
               --extract \
               --file /tmp/postgresql.tar.gz \
               --directory /usr/src/postgresql \
               --strip-components 1 \
        && rm /tmp/postgresql.tar.gz \
        && cd /usr/src/postgresql \
        \
# update "DEFAULT_PGSOCKET_DIR" to "/var/run/postgresql" (matching Debian)
# see https://anonscm.debian.org/git/pkg-postgresql/postgresql.git/tree/debian/patches/51-default-sockets-in-var.patch?id=8b539fcb3e093a521c095e70bdfa76887217b89f
        && awk '$1 == "#define" && $2 == "DEFAULT_PGSOCKET_DIR" && $3 == "\"/tmp\"" { $3 = "\"/var/run/postgresql\""; print; next } { print }' src/include/pg_config_manual.h > src/include/pg_config_manual.h.new \
        && grep '/var/run/postgresql' src/include/pg_config_manual.h.new \
        && mv src/include/pg_config_manual.h.new src/include/pg_config_manual.h \
        \
        && gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)" \
        && eval "$(dpkg-buildflags --export=sh)" \
        && export LDFLAGS="$LDFLAGS -s -w" \
        && ./configure \
               --build="$gnuArch" \
               --enable-nls \
               --enable-integer-datetimes \
               --enable-thread-safety \
               --enable-tap-tests \
#              --enable-debug \
#              --disable-rpath \
               --with-uuid=e2fs \
               --with-gnu-ld \
               --with-pgport=5432 \
               --with-system-tzdata=/usr/share/zoneinfo \
               --prefix=/usr/lib/postgresql/$PG_MAJOR \
               --with-includes=/usr/lib/postgresql/$PG_MAJOR/include \
               --with-libraries=/usr/lib/postgresql/$PG_MAJOR/lib \
#              --with-krb5 \
#              --with-gssapi \
#              --with-ldap \
#              --with-tcl \
#              --with-perl \
               --with-python \
#              --with-pam \
               --with-openssl \
               --with-libxml \
               --with-libxslt \
               --with-icu \
               --with-llvm  \
        && make -j8 world \
        && make -j8 install-world \
        && make -j8 -C contrib install \
        \
        # install repmgr
        && wget -O /tmp/repmgr.tar.gz https://github.com/2ndQuadrant/repmgr/archive/${REPMGR_VERSION}.tar.gz \
        && mkdir -p /usr/src/repmgr \
        && tar \
                --extract \
                --file /tmp/repmgr.tar.gz \
                --directory /usr/src/repmgr \
                --strip-components 1 \
        && rm /tmp/repmgr.tar.gz \
        && cd /usr/src/repmgr \
        \
        && eval "$(dpkg-buildflags --export=sh)" \
        && export LDFLAGS="$LDFLAGS -s -w" \
        && ./configure \
        && make -j8 \
        && make -j8 install \
	\
	&& mkdir /etc/repmgr \
	&& chown postgres: /etc/repmgr \
        \
        # install pglogical
        && wget -O /tmp/pglogical.tar.gz https://github.com/2ndQuadrant/pglogical/archive/${PGLOGICAL_VERSION}.tar.gz \
        && mkdir -p /usr/src/pglogical \
        && tar \
                --extract \
                --file /tmp/pglogical.tar.gz \
                --directory /usr/src/pglogical \
                --strip-components 1 \
        && rm /tmp/pglogical.tar.gz \
        && cd /usr/src/pglogical \
        \
        && eval "$(dpkg-buildflags --export=sh)" \
        && export LDFLAGS="$LDFLAGS -s -w" \
        && make -j8 \
        && make -j8 install \
        \
        # cleanup
        && apt-mark auto '.*' > /dev/null \
        && apt-mark manual $(cat /tmp/aptmark)  > /dev/null \
        && find /usr/lib/postgresql -type f -executable -exec ldd '{}' ';' \
                | awk '/=>/ { print $(NF-1) }' \
                | sort -u \
                | xargs -i readlink -f {} \
                | xargs -r dpkg-query --search 2>/dev/null \
                | cut -d: -f1 \
                | sort -u \
                | xargs -r apt-mark manual \
        && find /usr/lib/postgresql -type f -executable -exec ldd '{}' ';' \
                | awk '/=>/ { print $(NF-1) }' \
                | sort -u \
                | xargs -r dpkg-query --search 2>/dev/null \
                | cut -d: -f1 \
                | sort -u \
                | xargs -r apt-mark manual \
        && apt-mark manual gosu locales dnsutils xinetd \
        && apt-get purge -y --auto-remove \
                wget \
                gcc \
               make \
               cmake \
               dpkg-dev \
                automake \
                autoconf \
                libtool \
                libunwind-dev \
                bison \
                flex \
                libedit-dev \
                libxml2-dev \
                libxslt-dev \
                llvm-dev \
                clang \
                libssl-dev \
                python3-dev \
                zlib1g-dev \
                libicu-dev \
#               libpam0g-dev \
                pkg-config \
                uuid-dev \
                gettext \
               perl \
                libipc-run-perl \
        && apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false \
        && apt-get clean \
        && cd / \
        && rm -rf \
               /usr/src/* \
               /usr/local/share/doc \
               /usr/local/share/man \
                /tmp/aptmark \
        \
        # make the sample config easier to munge (and "correct by default")
        && sed -ri "s!^#?(listen_addresses)\s*=\s*\S+.*!\1 = '*'!" /usr/lib/postgresql/$PG_MAJOR/share/postgresql.conf.sample \
        \
        && mkdir -p /var/run/postgresql && chown -R postgres:postgres /var/run/postgresql && chmod 2777 /var/run/postgresql \
        && mkdir -p "$PGDATA" && chown -R postgres:postgres "$PGDATA" && chmod 700 "$PGDATA"

#VOLUME /var/lib/postgresql/data

WORKDIR /var/lib/postgresql

COPY docker-entrypoint.sh /usr/local/bin/

ENTRYPOINT ["docker-entrypoint.sh"]

STOPSIGNAL SIGINT

USER 70

EXPOSE 5432
CMD ["postgres"]

