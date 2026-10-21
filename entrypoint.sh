#!/bin/sh -l

set -e

# PHP-CS-Fixer 3.13.0 declares max PHP 8.1.*; we run on 8.2 for parity with
# app images. Official 8.2 support starts at Fixer 3.15.0 (ruleset bump — do
# separately). Until then, allow the runtime so dry-run CI can execute.
export PHP_CS_FIXER_IGNORE_ENV=1

/usr/local/bin/php-cs-fixer --version
/usr/local/bin/php-cs-fixer fix $*
