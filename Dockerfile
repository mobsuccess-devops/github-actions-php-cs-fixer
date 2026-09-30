FROM --platform=linux/amd64 php:8.1.34-cli-alpine

LABEL "com.github.actions.name"="PHP-CS-Fixer"
LABEL "com.github.actions.description"="check php files"
LABEL "com.github.actions.icon"="check"
LABEL "com.github.actions.color"="blue"

# Pin PHP 8.1.34 to match mobsuccess (same digest as php:8.1-alpine today).
RUN wget -O /usr/local/bin/php-cs-fixer \
      https://github.com/FriendsOfPHP/PHP-CS-Fixer/releases/download/v3.13.0/php-cs-fixer.phar \
    && chmod a+x /usr/local/bin/php-cs-fixer

COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
