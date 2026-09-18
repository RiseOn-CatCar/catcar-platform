set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

default:
    @just --list

dev:
    cd catcar-app && aspire start --non-interactive

build:
    dotnet build catcar-app/CatCar.slnx

test:
    dotnet test catcar-app/CatCar.slnx

format:
    dotnet format catcar-app/CatCar.slnx

infra-validate:
    terraform -chdir=catcar-database-infra init -backend=false
    terraform -chdir=catcar-database-infra validate
    terraform -chdir=catcar-kubernetes-infra init -backend=false
    terraform -chdir=catcar-kubernetes-infra validate

git-status:
    git status --short --branch
    git submodule status

git-sync:
    git pull --rebase
    git submodule update --init --recursive
    git submodule update --remote --merge

restore:
    dotnet restore catcar-app/CatCar.slnx
