#!/usr/bin/env bash
set -euo pipefail

# Log file for actions and diagnostics
LOGFILE="${HOME}/.uni-config.log"
echo "==== $(date -Iseconds) ====" >> "$LOGFILE"

# Early help handler: show help and exit before doing any work
if [ "$#" -gt 0 ]; then
	for _arg in "$@"; do
		case "$_arg" in
			-h|--help)
				cat <<'EOF'
Usage: ./utils/config.sh [all|apt|pip|conda|java-manager|gh|gh-login|record <note>]

Commands:
  all         : Install apt, pip, conda and Java manager (and gh), then prompt login
  apt         : Install apt packages (and gh)
  pip         : Install pip packages
  conda       : Install Miniconda (Anaconda manager)
  java-manager: Install SDKMAN and a Java runtime via SDKMAN
  gh          : Install GitHub CLI (gh) only
	gh-login    : Prompt for gh auth login (requires gh installed)
	git-config  : Configure global git user.name/user.email (interactive or via gh)
	clone       : Clone or update https://github.com/0dvn/uni into ~/docs
	record      : Append a manual note to the log
  -h|--help   : Show this help
EOF
				exit 0
				;;
		esac
	done
fi

# -----------------------------
# Helper utilities
# -----------------------------

# Return true (0) if package is NOT installed (so we need to install it)
apt_needed() {
	dpkg -s "$1" &>/dev/null || return 0
	return 1
}

# Update apt caches if they have not been updated in the last hour
ensure_apt_update() {
	if [ ! -f /var/lib/apt/periodic/update-success-stamp ] || [ "$(find /var/lib/apt/periodic/update-success-stamp -mmin +60)" ]; then
		sudo apt-get update
	fi
}

# -----------------------------
# APT, pipx, npm installers
# -----------------------------

# Install a set of essential APT packages
install_apt_packages() {
		ensure_apt_update
	    local pkgs=(git curl wget build-essential ca-certificates unzip zip python3-pip python3-venv pipx \
		libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev libncurses-dev \
		xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev)
	local to_install=()

	for p in "${pkgs[@]}"; do
		if apt_needed "$p"; then
			to_install+=("$p")
		fi
	done

	if [ "${#to_install[@]}" -gt 0 ]; then
		echo "Installing APT: ${to_install[*]}" | tee -a "$LOGFILE"
		sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${to_install[@]}"
	else
		echo "APT packages already present" >> "$LOGFILE"
	fi

	# Ensure gh (GitHub CLI) is present after base APT packages
	install_gh
}

# Install pip-based packages (try user pip, fall back to apt if pip is blocked)
install_pip_packages() {
	local pkgs=(pipx)

	# Ensure pip is available; if not, install python3-pip and venv support via APT
	if ! python3 -m pip --version >/dev/null 2>&1; then
		echo "pip not found; installing python3-pip and python3-venv via APT" | tee -a "$LOGFILE"
		ensure_apt_update
		sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3-pip python3-venv || true
	fi

	for p in "${pkgs[@]}"; do
		if ! command -v "$p" >/dev/null 2>&1; then
			echo "Installing $p (try pip user, fallback to apt)" | tee -a "$LOGFILE"

			if python3 -m pip install --user "$p"; then
				echo "$p installed via pip (user)" >> "$LOGFILE"
			else
				echo "pip install failed for $p (possible PEP 668); installing via APT" | tee -a "$LOGFILE"
				ensure_apt_update
				sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$p" python3-venv || true
			fi
		fi
	done

	# Ensure pipx path is available for the user
	if command -v pipx >/dev/null 2>&1; then
		pipx ensurepath >/dev/null 2>&1 || true
	fi
}

# -----------------------------
# pyenv installation
# -----------------------------

# Install pyenv (manages CPython versions). We install dependencies via APT
# and clone pyenv into $HOME/.pyenv; we add initialization to ~/.bashrc if needed.
install_pyenv() {
	if [ -d "$HOME/.pyenv" ]; then
		echo "pyenv already installed" >> "$LOGFILE"
		return 0
	fi

	echo "Installing pyenv (Python version manager)" | tee -a "$LOGFILE"

	# Ensure required build deps are installed (they are included in install_apt_packages pkgs)
	ensure_apt_update
	sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
		build-essential curl git libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev \
		libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev || true

	git clone https://github.com/pyenv/pyenv.git "$HOME/.pyenv" || {
		echo "Failed to clone pyenv" | tee -a "$LOGFILE"
		return 1
	}

	# Add initialization to ~/.bashrc if not present
	if ! grep -q 'PYENV_ROOT' "$HOME/.bashrc" 2>/dev/null; then
		cat >> "$HOME/.bashrc" <<'EOF'
# pyenv
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
if command -v pyenv 1>/dev/null 2>&1; then
  eval "$(pyenv init -)"
fi
EOF
	fi

	# Initialize in current shell session where possible
	export PYENV_ROOT="$HOME/.pyenv"
	export PATH="$PYENV_ROOT/bin:$PATH"
	if command -v pyenv >/dev/null 2>&1; then
		eval "$(pyenv init -)" || true
	fi

	echo "pyenv installed at $HOME/.pyenv" >> "$LOGFILE"
}

# -----------------------------
# Clone repo 0dvn/uni into ~/docs
# -----------------------------

clone_uni_repo() {
	local repo_url="https://github.com/0dvn/uni.git"
	local dest="$HOME/docs"

	# Ensure git is available
	if ! command -v git >/dev/null 2>&1; then
		echo "git not found; installing git via APT" | tee -a "$LOGFILE"
		ensure_apt_update
		sudo DEBIAN_FRONTEND=noninteractive apt-get install -y git || true
	fi

	if [ -d "$dest/.git" ]; then
		echo "Repository already cloned in $dest — fetching updates" | tee -a "$LOGFILE"
		git -C "$dest" fetch --all --prune || true
		git -C "$dest" pull --ff-only || true
	else
		echo "Cloning $repo_url into $dest" | tee -a "$LOGFILE"
		mkdir -p "$dest"
		git clone "$repo_url" "$dest" || {
			echo "Failed to clone $repo_url" | tee -a "$LOGFILE"
			return 1
		}
	fi
	echo "Repository 0dvn/uni is present at $dest" >> "$LOGFILE"
}

# Install npm global packages if npm is available
# (Removed npm/global node installation — not used for now)

# -----------------------------
# Python manager (Anaconda/Miniconda)
# -----------------------------

# Install Miniconda (provides conda/anaconda-like manager). This
# installs Miniconda in $HOME/miniconda3 non-interactively and initializes it.
install_python_manager() {
	if [ -x "$HOME/miniconda3/bin/conda" ]; then
		echo "conda (miniconda) already installed" >> "$LOGFILE"
		return 0
	fi

	echo "Installing Miniconda (Anaconda manager)" | tee -a "$LOGFILE"
	local installer="/tmp/Miniconda3-latest-Linux-x86_64.sh"
	curl -fsSL -o "$installer" https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh
	bash "$installer" -b -p "$HOME/miniconda3"
	rm -f "$installer"

	# Initialize conda for bash and do a first update
	"$HOME/miniconda3/bin/conda" init bash || true
	# Use a non-interactive update to ensure base environment is ready
	"$HOME/miniconda3/bin/conda" update -n base -c defaults conda -y || true

	# Accept Anaconda channel Terms of Service non-interactively (if conda binary available)
	if [ -x "$HOME/miniconda3/bin/conda" ]; then
		"$HOME/miniconda3/bin/conda" tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main || true
		"$HOME/miniconda3/bin/conda" tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r || true
	fi

	echo "Miniconda installed at $HOME/miniconda3" >> "$LOGFILE"
}

# -----------------------------
# Java manager (SDKMAN) and JDK install
# -----------------------------

# Install SDKMAN and attempt to install the latest available Java via SDKMAN.
install_java_manager() {
	if [ -d "$HOME/.sdkman" ]; then
		echo "SDKMAN already installed" >> "$LOGFILE"
	else
		echo "Installing SDKMAN (Java/version manager)" | tee -a "$LOGFILE"
		curl -s "https://get.sdkman.io" | bash || {
			echo "Failed to install SDKMAN" | tee -a "$LOGFILE"
			return 1
		}
	fi

	# Ensure sdkman is available in this script's environment and non-interactive
	bash -lc 'source "$HOME/.sdkman/bin/sdkman-init.sh" && export SDKMAN_NON_INTERACTIVE=true && echo "SDKMAN initialized"' || true

	# Try to detect a candidate latest JDK identifier and install it.
	# This uses sdk list java output and picks the first available identifier.
	# Parse sdk list java table: pick the first non-empty Identifier column value
	latest_id=$(bash -lc 'source "$HOME/.sdkman/bin/sdkman-init.sh" >/dev/null 2>&1 && SDKMAN_NON_INTERACTIVE=true sdk list java 2>/dev/null | awk -F"|" '\''NF>1{gsub(/^ +| +$/,"",$NF); if($NF!="Identifier") print $NF}'\'' | grep -v "^$" | head -n1' || true)

	if [ -n "$latest_id" ]; then
		echo "Installing Java via SDKMAN: $latest_id" | tee -a "$LOGFILE"
		bash -lc "source \"$HOME/.sdkman/bin/sdkman-init.sh\" && SDKMAN_NON_INTERACTIVE=true sdk install java $latest_id" || {
			echo "Failed to install Java $latest_id via SDKMAN" | tee -a "$LOGFILE"
			return 1
		}
		echo "Java $latest_id installed" >> "$LOGFILE"
	else
		echo "Could not determine latest Java identifier via SDKMAN; please run 'sdk list java' and install manually" | tee -a "$LOGFILE"
	fi
}

# -----------------------------
# GitHub CLI (gh) installation
# -----------------------------

# Install GitHub CLI (`gh`) from the official GitHub package repository
# If `gh` is already installed this is a no-op.
install_gh() {
  if command -v gh >/dev/null 2>&1; then
    echo "gh already installed" >> "$LOGFILE"
    return 0
  fi

  echo "Installing GitHub CLI (gh)" | tee -a "$LOGFILE"

  # Ensure wget exists (install_apt_packages should cover it, but be safe)
  (type -p wget >/dev/null || (sudo apt-get update && sudo apt-get install -y wget)) \
    && sudo mkdir -p -m 755 /etc/apt/keyrings \
    && out=$(mktemp) && wget -nv -O"$out" https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    && sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg < "$out" > /dev/null \
    && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && sudo mkdir -p -m 755 /etc/apt/sources.list.d \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && sudo apt-get update \
    && sudo apt-get install -y gh

  if command -v gh >/dev/null 2>&1; then
    echo "gh installed" >> "$LOGFILE"
  else
    echo "Failed to install gh via apt" | tee -a "$LOGFILE"
    return 1
  fi
}

# Prompt the user to authenticate with GitHub via `gh auth login`.
# This runs interactively if the script is run in a terminal. Failures are
# logged but do not cause the script to exit (preserve interactive flow).
prompt_gh_login() {
	if command -v gh >/dev/null 2>&1; then
		echo "Starting GitHub CLI login prompt..." | tee -a "$LOGFILE"
		# Run the interactive login; allow it to fail without aborting the script
		gh auth login || echo "gh auth login skipped or failed" | tee -a "$LOGFILE"
	else
		echo "gh not found; skipping login prompt" >> "$LOGFILE"
	fi
}

# -----------------------------
# Git configuration (user.name / user.email)
# -----------------------------

# Ensure global git user.name and user.email are set.
# - If gh is authenticated, try to obtain name/email via GitHub API.
# - If not, prompt the user interactively (only in a TTY).
install_git_config() {
	# check existing config
	cur_name=$(git config --global user.name 2>/dev/null || true)
	cur_email=$(git config --global user.email 2>/dev/null || true)
	if [ -n "$cur_name" ] && [ -n "$cur_email" ]; then
		echo "Git global user.name and user.email already set: $cur_name <$cur_email>" >> "$LOGFILE"
		return 0
	fi

	echo "Configuring global git user.name and user.email" | tee -a "$LOGFILE"

	# Try to get values from gh if authenticated
	if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
		gh_name=$(gh api user --jq .name 2>/dev/null || true)
		gh_email=$(gh api user --jq .email 2>/dev/null || true)
		# fallback: use login as name if name empty
		if [ -z "$gh_name" ]; then
			gh_name=$(gh api user --jq .login 2>/dev/null || true)
		fi
		if [ -n "$gh_name" ] && [ -z "$cur_name" ]; then
			git config --global user.name "$gh_name"
			echo "Set git user.name from gh: $gh_name" >> "$LOGFILE"
		fi
		if [ -n "$gh_email" ] && [ -z "$cur_email" ]; then
			git config --global user.email "$gh_email"
			echo "Set git user.email from gh: $gh_email" >> "$LOGFILE"
		fi
	fi

	# Re-check
	cur_name=$(git config --global user.name 2>/dev/null || true)
	cur_email=$(git config --global user.email 2>/dev/null || true)
	if [ -n "$cur_name" ] && [ -n "$cur_email" ]; then
		echo "Git configured: $cur_name <$cur_email>" >> "$LOGFILE"
		return 0
	fi

	# If in interactive terminal, prompt the user
	if [ -t 0 ]; then
		if [ -z "$cur_name" ]; then
			read -rp "Git user.name: " in_name || true
			if [ -n "$in_name" ]; then
				git config --global user.name "$in_name"
				echo "Set git user.name to $in_name" >> "$LOGFILE"
			fi
		fi
		if [ -z "$cur_email" ]; then
			read -rp "Git user.email: " in_email || true
			if [ -n "$in_email" ]; then
				git config --global user.email "$in_email"
				echo "Set git user.email to $in_email" >> "$LOGFILE"
			fi
		fi
	else
		echo "Non-interactive shell and git user config missing. Please run:" | tee -a "$LOGFILE"
		echo "  git config --global user.name \"Your Name\"" | tee -a "$LOGFILE"
		echo "  git config --global user.email \"you@example.com\"" | tee -a "$LOGFILE"
	fi

	git config --global init.defaultBranch main # main branch supremacy!!
}

# -----------------------------
# Git Subtree Aliases
# -----------------------------

# Add subpush and subpull aliases to simplify subtree management
install_subtree_aliases() {
	echo "Installing Git subtree aliases (subinit, subpush, subpull)" | tee -a "$LOGFILE"
	
	git config --global alias.subinit '!f() { \
		dir="${1%/}"; url="$2"; branch="${3:-main}"; \
		if [ -z "$dir" ] || [ -z "$url" ]; then echo "Usage: git subinit <dir> <url> [branch]" >&2; return 1; fi; \
		mkdir -p "$dir"; \
		root="$(git rev-parse --show-toplevel)"; \
		echo "$url $branch $root" > "$dir/.subrepo"; \
	}; f'

	git config --global alias.subpush '!f() { \
		target_dir=""; branch_arg=""; \
		while [ $# -gt 0 ]; do \
			case "$1" in \
				-b) branch_arg="$2"; shift 2 ;; \
				-*) shift ;; \
				*) target_dir="$1"; shift ;; \
			esac; \
		done; \
		repo_root="$(pwd)"; \
		user_prefix="${GIT_PREFIX%/}"; \
		if [ -n "$user_prefix" ] && [ -f "$user_prefix/.subrepo" ]; then \
			subrepo_dir="$repo_root/$user_prefix"; \
		elif [ -n "$target_dir" ] && [ -f "$target_dir/.subrepo" ]; then \
			subrepo_dir="$repo_root/${target_dir%/}"; \
		elif [ -f ".subrepo" ]; then \
			subrepo_dir="$repo_root"; \
		else \
			echo "Error: .subrepo not found. (Current Git prefix: $GIT_PREFIX)" >&2; return 1; \
		fi; \
		read -r url saved_branch saved_root < "$subrepo_dir/.subrepo"; \
		branch="${branch_arg:-$saved_branch}"; \
		prefix="${subrepo_dir#$repo_root/}"; \
		if [ "$subrepo_dir" = "$repo_root" ]; then prefix="."; fi; \
		if [ "$branch" != "$saved_branch" ]; then \
			echo "$url $branch $repo_root" > "$subrepo_dir/.subrepo"; \
		fi; \
		git subtree push --prefix="$prefix" "$url" "$branch"; \
	}; f'
		
	git config --global alias.subpull '!f() { \
		target_dir=""; branch_arg=""; \
		while [ $# -gt 0 ]; do \
			case "$1" in \
				-b) branch_arg="$2"; shift 2 ;; \
				-*) shift ;; \
				*) target_dir="$1"; shift ;; \
			esac; \
		done; \
		repo_root="$(pwd)"; \
		user_prefix="${GIT_PREFIX%/}"; \
		if [ -n "$user_prefix" ] && [ -f "$user_prefix/.subrepo" ]; then \
			subrepo_dir="$repo_root/$user_prefix"; \
		elif [ -n "$target_dir" ] && [ -f "$target_dir/.subrepo" ]; then \
			subrepo_dir="$repo_root/${target_dir%/}"; \
		elif [ -f ".subrepo" ]; then \
			subrepo_dir="$repo_root"; \
		else \
			echo "Error: .subrepo not found. (Current Git prefix: $GIT_PREFIX)" >&2; return 1; \
		fi; \
		read -r url saved_branch saved_root < "$subrepo_dir/.subrepo"; \
		branch="${branch_arg:-$saved_branch}"; \
		prefix="${subrepo_dir#$repo_root/}"; \
		if [ "$subrepo_dir" = "$repo_root" ]; then prefix="."; fi; \
		echo "[DEBUG] Root: $repo_root | Subrepo: $subrepo_dir | Prefix: $prefix"; \
		if [ "$branch" != "$saved_branch" ]; then \
			echo "$url $branch $repo_root" > "$subrepo_dir/.subrepo"; \
		fi; \
		git subtree pull --prefix="$prefix" "$url" "$branch" --squash; \
	}; f'

	echo "Subtree aliases installed: subpush, subpull" >> "$LOGFILE"
}

# -----------------------------
# Utilities
# -----------------------------

record_manual() {
	echo "MANUAL: $*" | tee -a "$LOGFILE"
}

usage() {
	cat <<EOF
Usage: $0 [all|apt|pip|conda|java-manager|gh|gh-login|record <note>]

Commands:
	all         : Install apt, pip, conda and Java manager (and gh), then prompt login
	apt         : Install apt packages (and gh)
	pip         : Install pip packages
	conda       : Install Miniconda (Anaconda manager)
	java-manager: Install SDKMAN and a Java runtime via SDKMAN
	gh          : Install GitHub CLI (`gh`) only
	gh-login    : Prompt for `gh auth login` (requires `gh` installed)
	git-config  : Configure global git user.name/user.email and subtree aliases
	record      : Append a manual note to the log
	-h|--help   : Show this help
EOF
}

print_done() {
	echo "Done!" >> "$LOGFILE"
}

# -----------------------------
# Main entrypoint
# -----------------------------
case "${1:-all}" in
	all)
		install_apt_packages
		install_pip_packages
		install_python_manager
		install_java_manager
		prompt_gh_login
		install_git_config
		install_subtree_aliases
		print_done
		;;

	apt)
		install_apt_packages
		prompt_gh_login
		print_done
		;;

	pip)
		install_pip_packages
		print_done
		;;

	conda)
		install_python_manager
		print_done
		;;

	java-manager)
		install_java_manager
		print_done
		;;

	clone)
		clone_uni_repo
		print_done
		;;

	gh)
		install_gh
		print_done
		;;

	gh-login)
		prompt_gh_login
		print_done
		;;

	git-config)
		install_git_config
		install_subtree_aliases
		print_done
		;;

	record)
		shift || true
		record_manual "$*"
		;;

	-h|--help)
		usage
		exit 0
		;;

	*)
		echo "Unknown action: $1"
		usage
		exit 2
		;;
esac