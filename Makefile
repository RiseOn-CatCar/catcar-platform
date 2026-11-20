SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

.PHONY: help dev build test format infra-validate git-status git-sync restore kind-up kind-validate verify-release verify-component-checks deploy-azure azure-teardown-plan azure-teardown

help:
	@printf "%s\n\n%s\n  %-16s %s\n  %-16s %s\n  %-16s %s\n  %-16s %s\n  %-16s %s\n  %-16s %s\n  %-16s %s\n  %-16s %s\n  %-16s %s\n" \
		"Usage: make [target]" \
		"Available targets:" \
		"help" "Show this help message" \
		"dev" "Run the Aspire AppHost locally" \
		"build" "Build all .NET solutions" \
		"test" "Run tests for all .NET solutions" \
		"format" "Format .NET code and Terraform configurations" \
		"infra-validate" "Validate database and Kubernetes Terraform configurations" \
		"git-status" "Show platform repository and submodule status" \
		"git-sync" "Pull platform changes and synchronize submodules" \
		"restore" "Restore dependencies for all .NET solutions"
	@printf "  %-24s %s\n" \
		"kind-up" "Create or reuse the local Kind cluster and registry" \
		"kind-validate" "Build and validate the staged Kind deployment" \
		"verify-release" "Verify release (set TAG and COMMIT)" \
		"verify-component-checks" "Verify component CI checks for the release" \
		"deploy-azure" "Deploy a validated release (set PHASE and ARTIFACTS_DIR)" \
		"azure-teardown-plan" "Preview Azure teardown" \
		"azure-teardown" "Destroy Azure deployment (set CONFIRM=rg-catcar)"

# Run the platform Aspire AppHost locally.
dev:
	aspire start --apphost aspire/CatCar.AppHost/CatCar.AppHost.csproj --non-interactive

build:
	dotnet build catcar-os-service/CatCar.slnx
	dotnet build catcar-billing-service/CatCar.Billing.slnx
	dotnet build catcar-execution-service/CatCar.Execution.slnx
	dotnet build CatCar.Platform.slnx
	dotnet build catcar-auth-function/CatCar.AuthFunction.slnx

test:
	dotnet test catcar-os-service/CatCar.slnx
	dotnet test catcar-billing-service/CatCar.Billing.slnx
	dotnet test catcar-execution-service/CatCar.Execution.slnx
	dotnet test catcar-auth-function/CatCar.AuthFunction.slnx

format:
	dotnet format catcar-os-service/CatCar.slnx
	dotnet format catcar-billing-service/CatCar.Billing.slnx
	dotnet format catcar-execution-service/CatCar.Execution.slnx
	dotnet format CatCar.Platform.slnx
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
	dotnet restore catcar-os-service/CatCar.slnx
	dotnet restore catcar-billing-service/CatCar.Billing.slnx
	dotnet restore catcar-execution-service/CatCar.Execution.slnx
	dotnet restore CatCar.Platform.slnx
	dotnet restore catcar-auth-function/CatCar.AuthFunction.slnx

kind-up:
	./scripts/kind-with-registry.sh

kind-validate:
	./scripts/validate-kind.sh

verify-release:
	@test -n "$(TAG)" && test -n "$(COMMIT)" || { echo "Set TAG and COMMIT" >&2; exit 1; }
	./scripts/verify-release.sh --tag "$(TAG)" --commit "$(COMMIT)" --repository-root .

verify-component-checks:
	./scripts/verify-component-checks.sh --repository-root .

deploy-azure:
	@test -n "$(PHASE)" && test -n "$(ARTIFACTS_DIR)" || { echo "Set PHASE and ARTIFACTS_DIR" >&2; exit 1; }
	./scripts/deploy-azure.sh --phase "$(PHASE)" --artifacts-dir "$(ARTIFACTS_DIR)"

azure-teardown-plan:
	./scripts/teardown-azure.sh

azure-teardown:
	@test "$(CONFIRM)" = "rg-catcar" || { echo "Set CONFIRM=rg-catcar" >&2; exit 1; }
	./scripts/teardown-azure.sh --apply --confirm "$(CONFIRM)"
