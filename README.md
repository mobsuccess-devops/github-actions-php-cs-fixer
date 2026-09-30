# GithubAction for PHP-CS-Fixer

## Usage

You can use it as a Github Action like this:

_.github/workflows/lint.yml_
```yaml
on: [push, pull_request]
name: Main
jobs:
  php-cs-fixer:
    name: PHP-CS-Fixer
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4
    - name: PHP-CS-Fixer
      uses: mobsuccess-devops/github-actions-php-cs-fixer@master
```

_to use a custom config for example, --diff and --dry-run option:_
```diff
on: [push, pull_request]
name: Main
jobs:
  php-cs-fixer:
    name: PHP-CS-Fixer
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4
    - name: PHP-CS-Fixer
      uses: mobsuccess-devops/github-actions-php-cs-fixer@master
+      with:
+        args: --config=.project.php_cs --diff --dry-run
```

The action builds its Docker image from the repository `Dockerfile` on the runner, so CI does not pull `public.ecr.aws/...` anonymously (which hits ECR Public data limits on shared GitHub runner IPs).

Prefer `uses: mobsuccess-devops/github-actions-php-cs-fixer@...` over `uses: docker://public.ecr.aws/...`.

**You can copy/paste the .github folder (under examples/) to your project and thats all!**

## Docker

You can still build and run the image locally:

`docker compose build`

`docker run --rm -it -w=/app -v ${PWD}:/app public.ecr.aws/u9q7y3l4/github-actions-php-cs-fixer:v3.13.0`

## A picture is worth a thousand words

You can find a working and not working PR here:
https://github.com/OskarStark/test-php-cs-fixer-ga/pulls
