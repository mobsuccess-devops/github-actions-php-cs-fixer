FROM php:8.1.34-alpine

ARG PHP_CS_FIXER_VERSION=3.13.0
ARG PHP_CS_FIXER_SHA256=ac2e57e32cdae67f21baa88f78405f93d4d6e928f41ba62dc91505565c785a44

ADD --checksum=sha256:${PHP_CS_FIXER_SHA256} --chmod=755 \
    https://github.com/PHP-CS-Fixer/PHP-CS-Fixer/releases/download/v${PHP_CS_FIXER_VERSION}/php-cs-fixer.phar \
    /usr/local/bin/php-cs-fixer

COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
