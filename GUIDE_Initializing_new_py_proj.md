# Initializing a New Python Project with uv

## 1. Initialize the project

Use `--lib` for a `src/` layout and `--python` to pin the version:

```bash
uv init --lib --python 3.12
```

This creates:
- `src/<package_name>/__init__.py`
- `src/<package_name>/py.typed`
- `.python-version` (contains `3.12`)
- `pyproject.toml` (scaffold)
- `README.md`
- Initializes a git repo if one doesn't exist

## 2. Replace pyproject.toml

The generated `pyproject.toml` is minimal. Replace it with the full config:

```toml
[project]
name = "<project-name>"
version = "0.0.1"
description = "<description>"
readme = "README.md"
requires-python = "==3.12.*"
dependencies = []


[build-system]
requires = ["uv_build>=0.10.9,<0.11.0"]
build-backend = "uv_build"

[dependency-groups]
dev = [
    "pyright>=1.1.407",
    "pytest>=9.0.2",
    "ruff>=0.14.10",
]


[tool.ruff]
line-length = 88
indent-width = 4
target-version = "py312"
exclude = ["*.md"]

[tool.ruff.lint]
select = [
    "E",   # pycodestyle errors
    "W",   # pycodestyle warnings
    "F",   # Pyflakes
    "UP",  # pyupgrade
    "B",   # flake8-bugbear
    "I",   # isort
    "N",   # pep8-naming
    "TCH", # flake8-type-checking
    "FA",  # flake8-future-annotations
]
ignore = [
    "E501", # Line too long
    "F401", # Unused imports
    "F841", # Unused vars
]
fixable = ["ALL"]
unfixable = []

[tool.ruff.format]
quote-style = "double"
indent-style = "space"
skip-magic-trailing-comma = false
line-ending = "auto"
docstring-code-format = true

[tool.pytest.ini_options]
testpaths = ["tests"]
pythonpath = ["."]
addopts = "-v --tb=short"
```

Key differences from the generated default:
- `requires-python` pinned to `==3.12.*` (not `>=3.12`)
- `authors` field removed
- `version` starts at `0.0.1`
- Dev dependency group with ruff, pytest, pyright
- Full ruff lint + format config
- Pytest config pointing at `tests/`

## 3. Create the venv and sync

```bash
uv venv
uv sync
```

`uv venv` creates `.venv/` using the Python version from `.python-version`. `uv sync` installs all dependencies (including dev) and generates `uv.lock`.

## 4. Create the tests directory

```bash
mkdir -p tests
```

## 5. Update .gitignore

```gitignore
# Python-generated files
__pycache__/
*.py[oc]
build/
dist/
wheels/
*.egg-info

# Virtual environments
**/.venv

# Environment variables
**/.env

.ruff_cache/

# Editor directories and files
**/.vscode/*
.idea
.DS_Store
*.suo
*.ntvs*
*.njsproj
*.sln
*.sw?

# Claude related
src.md
**/CLAUDE.md
**/.claude
**/AGENTS.md
**/.agent/
REPOMAP.md
CODEGUIDE.md
**/.cursor
.mcp.json

.editorconfig
```

## 6. Create .editorconfig

```editorconfig
root = true

[*]
indent_style = space
indent_size = 4
```

## Final structure

```
<project-name>/
├── .editorconfig
├── .git/
├── .gitignore
├── .python-version        # "3.12"
├── .venv/
├── README.md
├── pyproject.toml
├── uv.lock
├── src/
│   └── <package_name>/
│       ├── __init__.py
│       └── py.typed
└── tests/
```

## Common commands

```bash
# Add a dependency
uv add <package>

# Add a dev dependency
uv add --group dev <package>

# Run a script
uv run python src/<package_name>/main.py

# Run tests
uv run pytest tests/

# Lint
uv run ruff check src/

# Format
uv run ruff format src/
```
