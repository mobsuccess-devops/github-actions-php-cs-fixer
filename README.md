# github-actions-php-cs-fixer

A Docker image that runs [PHP-CS-Fixer](https://github.com/PHP-CS-Fixer/PHP-CS-Fixer)
in a GitHub Actions workflow. Its arguments are passed to `php-cs-fixer fix`.

## Usage

```yaml
jobs:
  php-cs-fixer:
    name: PHP-CS-Fixer
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - name: PHP-CS-Fixer
        uses: docker://ghcr.io/mobsuccess-devops/github-actions-php-cs-fixer:v3.13.0
        with:
          args: --config=.php-cs-fixer.dist.php --diff --dry-run .
```

The tag is the PHP-CS-Fixer version. Keep it in the workflow: another version
has other rules, and would reformat the code it checks.

Locally, from the repository to check:

```bash
docker run --rm -v "$PWD:/app" -w /app ghcr.io/mobsuccess-devops/github-actions-php-cs-fixer:v3.13.0 --diff --dry-run .
```

## Image

A push to `master` that changes the `Dockerfile` or `entrypoint.sh` publishes
the image to `ghcr.io/mobsuccess-devops/github-actions-php-cs-fixer`
(`.github/workflows/docker.yml`), tagged with the PHP-CS-Fixer version. The
`Docker` workflow can also be run by hand.

Workflows pull it without credentials, so the package has to be public: keep
secrets out of the image. A package is private when first published; someone
with admin rights on it makes it public once (Package settings → Danger Zone →
Change visibility), which cannot be undone.

To move to another PHP-CS-Fixer version, change `PHP_CS_FIXER_VERSION` and
`PHP_CS_FIXER_SHA256` in the `Dockerfile` (the SHA-256 of the released
`php-cs-fixer.phar`), and the tag in `compose.yml` and in this file.

To build the image locally: `docker compose build`.
