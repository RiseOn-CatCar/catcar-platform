# CatCar Platform

CatCar Platform is the umbrella workspace for the CatCar application and its infrastructure repositories. It pins each component as a Git submodule so a checkout represents a known-compatible platform revision.

## Architecture and repositories

| Repository | Responsibility |
| --- | --- |
| [`catcar-app`](https://github.com/RiseOn-CatCar/catcar-app) | .NET application, Aspire AppHost, domain services, API, and tests. |
| [`catcar-auth-function`](https://github.com/RiseOn-CatCar/catcar-auth-function) | Azure Functions authentication service. |
| [`catcar-database-infra`](https://github.com/RiseOn-CatCar/catcar-database-infra) | Terraform for database infrastructure. |
| [`catcar-kubernetes-infra`](https://github.com/RiseOn-CatCar/catcar-kubernetes-infra) | Terraform and Kubernetes-related platform infrastructure. |

The AppHost in `catcar-app` resolves the authentication function from the sibling `catcar-auth-function` submodule.

## Quick start

Clone the platform and all pinned component revisions:

```bash
git clone --recurse-submodules https://github.com/RiseOn-CatCar/catcar-platform.git
cd catcar-platform
```

For an existing clone, initialize the components with:

```bash
git submodule update --init --recursive
```

Open `catcar.code-workspace` in VS Code for the four-repository workspace.

## Development workflow

Install the .NET SDK, Aspire CLI, and Terraform. Development workflows are managed via `make`.

```bash
make restore
make dev
make test
make infra-validate
```

- `make help` lists all available targets and descriptions.
- `make dev` starts the Aspire AppHost from `catcar-app`.
- `make build`, `make test`, and `make format` operate on the application solutions.
- `make infra-validate` initializes Terraform without a backend and validates both infrastructure modules.
- `make git-status` shows the platform and component revisions.

## Submodule management

The platform repository stores a specific commit for every component. Update all components to their tracked remote branches, then review and commit the resulting gitlink changes:

```bash
git submodule update --remote --merge
git status
git commit -am "chore: update platform components"
git push
```

To update a single component:

```bash
git submodule update --remote --merge catcar-app
git add catcar-app
git commit -m "chore: update catcar-app"
git push
```

To work on a component, enter its directory, commit and push its changes to that repository first, then return here and commit the updated submodule pointer.
