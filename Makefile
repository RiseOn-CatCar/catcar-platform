SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

.PHONY: help dev build test format infra-validate git-status git-sync restore

help:
	@printf "%s\n\n%s\n  %-16s %s\n  %-16s %s\n  %-16s %s\n  %-16s %s\n  %-16s %s\n  %-16s %s\n  %-16s %s\n  %-16s %s\n  %-16s %s\n" \
		"Usage: make [target]" \
		"Available targets:" \
		"help" "Show this help message" \
		"dev" "Run the Aspire AppHost locally" \
		"build" "Build all .NET solutions (app and auth function)" \
		"test" "Run tests for all .NET solutions" \
		"format" "Format .NET code and Terraform configurations" \
		"infra-validate" "Validate database and Kubernetes Terraform configurations" \
		"git-status" "Show platform repository and submodule status" \
		"git-sync" "Pull platform changes and synchronize submodules" \
		"restore" "Restore dependencies for all .NET solutions"

# Run the Aspire AppHost locally (Alternative: cd catcar-app && aspire start --non-interactive)
dev:
	dotnet run --project catcar-app/src/Host/CatCar.AppHost/CatCar.AppHost.csproj

build:
	dotnet build catcar-app/CatCar.slnx
	dotnet build catcar-auth-function/CatCar.AuthFunction.slnx

test:
	dotnet test catcar-app/CatCar.slnx
	dotnet test catcar-auth-function/CatCar.AuthFunction.slnx

format:
	dotnet format catcar-app/CatCar.slnx
	dotnet format catcar-auth-function/CatCar.AuthFunction.slnx
	terraform -chdir=catcar-database-infra fmt -recursive
	terraform -chdir=catcar-kubernetes-infra fmt -recursive

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
	dotnet restore catcar-app/CatCar.slnx
	dotnet restore catcar-auth-function/CatCar.AuthFunction.slnx
