FROM php:8.2.35-alpine

ARG PHP_CS_FIXER_VERSION=3.95.27
ARG PHP_CS_FIXER_SHA256=47231757eefdd08778e2bd047d98a63dfaad881006c8c1d1bc870d63be7f6a9b

ADD --checksum=sha256:${PHP_CS_FIXER_SHA256} --chmod=755 \
    https://github.com/PHP-CS-Fixer/PHP-CS-Fixer/releases/download/v${PHP_CS_FIXER_VERSION}/php-cs-fixer.phar \
    /usr/local/bin/php-cs-fixer

COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
