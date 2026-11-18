FROM php:8.5.12-alpine

ARG PHP_CS_FIXER_VERSION=3.95.30
ARG PHP_CS_FIXER_SHA256=401607e17017f42929f075f4eaf56d78ebe9f9aef9c9d328979756d6d3b64b9a

ADD --checksum=sha256:${PHP_CS_FIXER_SHA256} --chmod=755 \
    https://github.com/PHP-CS-Fixer/PHP-CS-Fixer/releases/download/v${PHP_CS_FIXER_VERSION}/php-cs-fixer.phar \
    /usr/local/bin/php-cs-fixer

COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
