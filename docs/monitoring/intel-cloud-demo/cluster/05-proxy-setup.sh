#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# cluster/05-proxy-setup.sh — configure a corporate HTTP/SOCKS proxy for the
# tools this toolkit drives: git/curl (kernel-source fetch), the Docker daemon
# and build client (base-image pulls + in-container apt/git/Go), and SSH to the
# cloud jump host. You state your proxy URL, no_proxy list, jump host and (if the
# proxy re-signs TLS) corporate CA once as PROXY_* in inventory.env; this script
# applies them so you don't hand-edit systemd drop-ins, ~/.docker/config.json,
# and ~/.ssh/config. Skip this whole script if the workstation has direct egress.
#
# TLS inspection: `env` trusts PROXY_CA for host-side git/curl/Go, and `docker`
# trusts it in the host store for the Docker daemon's registry pulls. In-container
# build stages (apt/dnf/git/Go inside the kernel/nri images) do NOT inherit the
# host store, so behind a TLS-inspecting proxy the CA must be added to each build
# context by hand (COPY it in + update-ca-certificates); this script does not
# configure that path.
#
#   eval "$(./05-proxy-setup.sh env)"   # export http(s)_proxy/no_proxy/CA into THIS shell
#   ./05-proxy-setup.sh docker          # write Docker daemon drop-in + client build proxy
#   ./05-proxy-setup.sh ssh [apply]     # print (or append) the jump-host ProxyCommand
#   ./05-proxy-setup.sh check           # verify git/docker/ssh reach the outside
#   ./05-proxy-setup.sh all             # docker + ssh apply + check (then eval the env line)
#
# inventory.env variables (see inventory.env.example):
#   PROXY_URL         http://host:port used for both http_proxy and https_proxy
#   PROXY_NO_PROXY    override the no_proxy list (a sane default is computed)
#   PROXY_JUMP_HOST   ssh host/alias to attach the ProxyCommand to (the cloud jump host)
#   PROXY_SSH_TYPE    http | socks5  (how ssh tunnels through the proxy; default http)
#   PROXY_SSH_HOSTPORT host:port for the ssh tunnel (default: derived from PROXY_URL)
#   PROXY_CA          path to the corporate root CA .pem (only if the proxy inspects TLS);
#                     trusted for host git/curl/Go and the Docker daemon's pulls
#   PROXY_GOPROXY     internal Go module proxy for the nri build (if proxy.golang.org is blocked)
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
load_inventory

proxy_required() {
  [[ -n "${PROXY_URL:-}" ]] || die "set PROXY_URL in inventory.env (e.g. http://proxy.example.com:912)"
}

# no_proxy default: loopback + the private ranges an allocation uses + the
# k3s pod/service CIDRs + cluster DNS suffixes, so SSH tunnels and in-cluster
# scrapes never get bounced to the proxy.
default_no_proxy() {
  echo "localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,10.42.0.0/16,10.43.0.0/16,.svc,.cluster.local"
}

no_proxy_value() { echo "${PROXY_NO_PROXY:-$(default_no_proxy)}"; }

# host:port the ssh ProxyCommand dials — explicit override or parsed from PROXY_URL.
proxy_ssh_hostport() {
  local hp="${PROXY_SSH_HOSTPORT:-}"
  [[ -n "$hp" ]] || hp="$(printf '%s' "$PROXY_URL" | sed -E 's#^[a-zA-Z]+://##; s#/.*$##')"
  echo "$hp"
}

# ncat is not installed everywhere (it ships in nmap, not in a base Ubuntu
# image); netcat-openbsd's -x/-X reaches the same proxy.
ssh_proxycommand() {
  local hp; hp="$(proxy_ssh_hostport)"
  local host="${hp%:*}" port="${hp##*:}"
  local have_ncat=0; command -v ncat >/dev/null && have_ncat=1
  # Fall back to netcat-openbsd only when it is actually installed; emitting an
  # `nc` ProxyCommand that cannot run would write a guaranteed-broken SSH config.
  if [[ "$have_ncat" -eq 0 ]] && ! command -v nc >/dev/null; then
    die "neither 'ncat' (nmap-ncat) nor 'nc' (netcat-openbsd) is installed — one is required for the proxy ProxyCommand; install one and re-run"
  fi
  case "${PROXY_SSH_TYPE:-http}" in
    http|http-connect)
      [[ "$have_ncat" -eq 1 ]] \
        && echo "ProxyCommand ncat --proxy ${host}:${port} --proxy-type http %h %p" \
        || echo "ProxyCommand nc -X connect -x ${host}:${port} %h %p" ;;
    socks5|socks)
      [[ "$have_ncat" -eq 1 ]] \
        && echo "ProxyCommand ncat --proxy ${host}:${port} --proxy-type socks5 %h %p" \
        || echo "ProxyCommand nc -X 5 -x ${host}:${port} %h %p" ;;
    *) die "PROXY_SSH_TYPE must be 'http' or 'socks5'" ;;
  esac
}

# ---- env: shell exports (source these; a script can't set the parent's env) ---
cmd_env() {
  proxy_required
  local np; np="$(no_proxy_value)"
  printf "export http_proxy='%s' https_proxy='%s' no_proxy='%s'\n" "$PROXY_URL" "$PROXY_URL" "$np"
  printf "export HTTP_PROXY='%s' HTTPS_PROXY='%s' NO_PROXY='%s'\n" "$PROXY_URL" "$PROXY_URL" "$np"
  if [[ -n "${PROXY_CA:-}" ]]; then
    printf "export SSL_CERT_FILE='%s' GIT_SSL_CAINFO='%s'\n" "$PROXY_CA" "$PROXY_CA"
  fi
  [[ -n "${PROXY_GOPROXY:-}" ]] && printf "export GOPROXY='%s'\n" "$PROXY_GOPROXY"
}

# ---- docker: daemon drop-in (base-image pulls) + client build proxy -----------
cmd_docker() {
  proxy_required
  local np; np="$(no_proxy_value)"

  log "K-proxy: writing Docker daemon proxy drop-in (sudo)"
  sudo mkdir -p /etc/systemd/system/docker.service.d
  sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf >/dev/null <<EOF
[Service]
Environment="HTTP_PROXY=$PROXY_URL"
Environment="HTTPS_PROXY=$PROXY_URL"
Environment="NO_PROXY=$np"
EOF
  # If the proxy re-signs TLS, trust its CA in the host store BEFORE the restart:
  # the Docker daemon uses the system trust store for registry pulls, so without
  # this base-image pulls fail with an unknown-authority error.
  if [[ -n "${PROXY_CA:-}" ]]; then
    [[ -r "$PROXY_CA" ]] || die "PROXY_CA=$PROXY_CA is not readable"
    if [[ -d /usr/local/share/ca-certificates ]]; then
      sudo install -m0644 "$PROXY_CA" /usr/local/share/ca-certificates/aet-proxy-ca.crt
      sudo update-ca-certificates >/dev/null
    elif [[ -d /etc/pki/ca-trust/source/anchors ]]; then
      sudo install -m0644 "$PROXY_CA" /etc/pki/ca-trust/source/anchors/aet-proxy-ca.pem
      sudo update-ca-trust
    else
      warn "no known CA trust dir; skipping host CA install for the Docker daemon"
    fi
    log "K-proxy: trusted $PROXY_CA in the host store for daemon registry pulls"
  fi
  sudo systemctl daemon-reload && sudo systemctl restart docker

  log "K-proxy: writing Docker client build proxy (~/.docker/config.json)"
  mkdir -p "$HOME/.docker"
  local cfg="$HOME/.docker/config.json"
  if command -v python3 >/dev/null 2>&1; then
    PROXY_URL="$PROXY_URL" NP="$np" CFG="$cfg" python3 - <<'PY'
import json, os
cfg = os.environ["CFG"]
try:
    with open(cfg) as f: data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}
p = os.environ["PROXY_URL"]
data.setdefault("proxies", {})["default"] = {
    "httpProxy": p, "httpsProxy": p, "noProxy": os.environ["NP"],
}
with open(cfg, "w") as f: json.dump(data, f, indent=2)
PY
  else
    [[ -f "$cfg" ]] && { cp "$cfg" "$cfg.bak"; warn "no python3; backed up existing config to $cfg.bak and rewrote it"; }
    cat > "$cfg" <<EOF
{
  "proxies": {
    "default": {
      "httpProxy": "$PROXY_URL",
      "httpsProxy": "$PROXY_URL",
      "noProxy": "$np"
    }
  }
}
EOF
  fi
  log "K-proxy: docker configured"
}

# ---- ssh: jump-host ProxyCommand (print, or append to ~/.ssh/config) ----------
cmd_ssh() {
  proxy_required
  local pc; pc="$(ssh_proxycommand)"
  local jh="${PROXY_JUMP_HOST:-<jump-host>}"
  local block; block="$(printf 'Host %s\n    %s\n' "$jh" "$pc")"

  if [[ "${1:-}" == "apply" ]]; then
    [[ -n "${PROXY_JUMP_HOST:-}" ]] || die "set PROXY_JUMP_HOST in inventory.env to append an ~/.ssh/config entry"
    local cf="$HOME/.ssh/config"; mkdir -p "$HOME/.ssh"; touch "$cf"; chmod 600 "$cf"
    # Ask ssh what it would actually use for this host (merges Host/Match
    # blocks and Include files), so we only skip when a ProxyCommand really
    # resolves for PROXY_JUMP_HOST — not when some unrelated host has one.
    # Match either flavour: ncat uses --proxy, netcat-openbsd -x.
    if ssh -G "$PROXY_JUMP_HOST" 2>/dev/null | grep -qiE '^proxycommand .*(--proxy|-x )'; then
      warn "ssh: a ProxyCommand for $PROXY_JUMP_HOST already resolves in your ssh config — not modifying $cf"
    else
      printf '\n# added by 05-proxy-setup.sh\n%s\n' "$block" >> "$cf"
      log "ssh: appended ProxyCommand for $PROXY_JUMP_HOST to $cf"
    fi
  else
    echo "# Add to ~/.ssh/config so the per-node ProxyJump rides over the corporate proxy:"
    echo "$block"
    echo "# (re-run with 'ssh apply' to append it for you; requires PROXY_JUMP_HOST)"
  fi
}

# ---- check: does the outside world respond through the proxy? -----------------
cmd_check() {
  proxy_required
  eval "$(cmd_env)"
  local ok=1
  log "check: git ls-remote github.com through the proxy..."
  if git ls-remote https://github.com/torvalds/linux HEAD >/dev/null 2>&1; then
    log "  outbound HTTPS/git OK"
  else warn "  outbound HTTPS/git FAILED — check PROXY_URL / PROXY_CA"; ok=0; fi

  if command -v docker >/dev/null 2>&1; then
    log "check: docker pull hello-world..."
    if docker pull -q hello-world >/dev/null 2>&1; then log "  docker base-image pull OK"
    else warn "  docker pull FAILED — run './05-proxy-setup.sh docker'"; ok=0; fi
  fi

  if [[ -n "${PROXY_JUMP_HOST:-}" ]]; then
    log "check: ssh $PROXY_JUMP_HOST..."
    if ssh -o BatchMode=yes -o ConnectTimeout=15 "$PROXY_JUMP_HOST" true 2>/dev/null; then
      log "  ssh $PROXY_JUMP_HOST OK"
    else warn "  ssh $PROXY_JUMP_HOST FAILED — run './05-proxy-setup.sh ssh apply'"; ok=0; fi
  fi
  [[ "$ok" == 1 ]] || die "one or more proxy checks failed (see above)"
  log "check: all proxy paths reachable"
}

cmd_all() {
  cmd_docker
  cmd_ssh apply
  cmd_check
  echo
  log "Now load the shell env into your current shell:  eval \"\$(./05-proxy-setup.sh env)\""
}

case "${1:-}" in
  env)    cmd_env ;;
  docker) cmd_docker ;;
  ssh)    cmd_ssh "${2:-}" ;;
  check)  cmd_check ;;
  all)    cmd_all ;;
  *) echo "usage: $0 {env|docker|ssh [apply]|check|all}" >&2; exit 2 ;;
esac
