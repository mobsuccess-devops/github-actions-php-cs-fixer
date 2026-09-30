FROM --platform=linux/amd64 alpine:3.19

LABEL "com.github.actions.name"="PHP-CS-Fixer"
LABEL "com.github.actions.description"="check php files"
LABEL "com.github.actions.icon"="check"
LABEL "com.github.actions.color"="blue"

# Official php:*-alpine images ship a full PHP toolchain; this action only
# needs a CLI runtime for the php-cs-fixer phar.
RUN apk add --no-cache \
      php82 \
      php82-phar \
      php82-mbstring \
      php82-tokenizer \
      php82-xml \
      php82-xmlwriter \
      php82-simplexml \
      php82-iconv \
      php82-session \
      wget \
    && ln -sf /usr/bin/php82 /usr/bin/php \
    && wget -O /usr/local/bin/php-cs-fixer \
      https://github.com/FriendsOfPHP/PHP-CS-Fixer/releases/download/v3.13.0/php-cs-fixer.phar \
    && chmod a+x /usr/local/bin/php-cs-fixer \
    && apk del wget

COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
