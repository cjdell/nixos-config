# PHP 7.4-FPM for christcentralpreston.co.uk (Concrete CMS 8.3.2 — needs the
# PHP 7 line; the pinned nixpkgs has no php74). Built from the official image,
# adding the extensions Concrete CMS 8 requires: gd (with FreeType + JPEG),
# intl, zip, plus mysqli/pdo_mysql and exif.
#
# The Debian bullseye base reached EOL in 2026 and its mirrors moved to
# archive.debian.org, hence the sources rewrite and relaxed Release expiry.
FROM docker.io/library/php:7.4-fpm

RUN set -eux; \
    sed -i -e 's|deb.debian.org|archive.debian.org|g' -e 's|security.debian.org|archive.debian.org|g' -e '/bullseye-updates/d' /etc/apt/sources.list; \
    printf 'Acquire::Check-Valid-Until "false";\n' > /etc/apt/apt.conf.d/99no-valid-until; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libjpeg62-turbo-dev \
        libpng-dev \
        libfreetype6-dev \
        libzip-dev \
        libonig-dev \
        libicu-dev; \
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-install -j"$(nproc)" gd intl zip mysqli pdo_mysql exif; \
    rm -rf /var/lib/apt/lists/*
