set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

default:
    @just --list

dev:
    dotnet run --project catcar-app/src/Host/CatCar.AppHost/CatCar.AppHost.csproj
    # Alternative: cd catcar-app && aspire start --non-interactive

build:
    dotnet build catcar-app/CatCar.slnx && dotnet build catcar-auth-function/CatCar.AuthFunction.slnx

test:
    dotnet test catcar-app/CatCar.slnx && dotnet test catcar-auth-function/CatCar.AuthFunction.slnx

format:
    dotnet format catcar-app/CatCar.slnx && dotnet format catcar-auth-function/CatCar.AuthFunction.slnx && terraform -chdir=catcar-database-infra fmt -recursive && terraform -chdir=catcar-kubernetes-infra fmt -recursive

infra-validate:
    terraform -chdir=catcar-database-infra init -backend=false
    terraform -chdir=catcar-database-infra validate
    terraform -chdir=catcar-kubernetes-infra init -backend=false
    terraform -chdir=catcar-kubernetes-infra validate
    terraform -chdir=catcar-kubernetes-infra/alerts init -backend=false
    terraform -chdir=catcar-kubernetes-infra/alerts validate

git-status:
    git status --short --branch
    git submodule status

git-sync:
    git pull --rebase
    git submodule update --init --recursive
    git submodule update --remote --merge

restore:
    dotnet restore catcar-app/CatCar.slnx && dotnet restore catcar-auth-function/CatCar.AuthFunction.slnx
