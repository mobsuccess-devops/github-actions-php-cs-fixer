FROM --platform=linux/amd64 php:8.1-alpine

LABEL "com.github.actions.name"="PHP-CS-Fixer"
LABEL "com.github.actions.description"="check php files"
LABEL "com.github.actions.icon"="check"
LABEL "com.github.actions.color"="blue"

RUN wget https://github.com/FriendsOfPHP/PHP-CS-Fixer/releases/download/v3.13.0/php-cs-fixer.phar -O php-cs-fixer \
    && chmod a+x php-cs-fixer \
    && mv php-cs-fixer /usr/local/bin/php-cs-fixer

ADD entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
