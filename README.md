<div align="center">

# claude-box

**Claude Code in a sealed container — reachable only over Tailscale, wired into a Buzz relay as an agent.**

[![Tests](https://github.com/wus-solutions/ClaudeBox/actions/workflows/tests.yml/badge.svg)](https://github.com/wus-solutions/ClaudeBox/actions/workflows/tests.yml)
![Docker Compose v2](https://img.shields.io/badge/Docker-Compose%20v2-2496ED?logo=docker&logoColor=white)
![Network: Tailscale only](https://img.shields.io/badge/network-Tailscale%20only-1F1F1F?logo=tailscale&logoColor=white)
![Published ports: none](https://img.shields.io/badge/published%20ports-none-3FB950)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

[**Interactive architecture diagram**](https://wus-solutions.github.io/ClaudeBox/architecture.en.html) · [Deutsche Fassung](README.de.md)

</div>

---

From the public internet this service does not exist. No published port, no domain,
no reverse-proxy entry. Two things reach the container: a device in your tailnet,
and a WebSocket the container itself dialled out to.

That is the whole idea. An agent that writes without asking should not be sitting
behind a password on a public address.

## Contents

- [How it fits together](#how-it-fits-together)
- [Requirements](#requirements)
- [Setup](#setup)
- [Access](#access)
- [Security](#security)
- [Deploying on Coolify](#deploying-on-coolify)
- [Tests](#tests)
- [Operating it](#operating-it)
- [Pitfalls](#pitfalls)
- [License](#license)

## How it fits together

Two services in one Compose stack:

```
┌─ tailscale ───────────────────────────────────────────┐
│  ghcr.io/tailscale/tailscale                          │
│  owns the network namespace, terminates HTTPS         │
└───────────────────────────────────────────────────────┘
          ▲ network_mode: "service:tailscale"
┌─ claude ──────────────────────────────────────────────┐
│  ttyd -i lo :7681 → tmux → claude                     │
│  buzz-acp ──outbound WSS──→ relay                     │
│      └─ stdio ─→ claude-agent-acp                     │
└───────────────────────────────────────────────────────┘
```

> **[Open the interactive diagram →](https://wus-solutions.github.io/ClaudeBox/architecture.en.html)**
> Panning, guided views, light/dark, SVG and PNG export. It is a single
> self-contained HTML file in [`docs/`](docs/) — open it locally if GitHub
> Pages is not enabled for this repository.

The `claude` container has **no network stack of its own**. It therefore cannot
structurally expose anything past the tailnet — the isolation rests on the
topology, not on flags being set correctly. `ttyd` additionally binds only to
`lo`, as a second line of defence.

`buzz-acp` opens the connection to the relay **outbound** and therefore needs no
inbound port.


## Requirements

- Docker with Compose v2
- A tailnet with **HTTPS certificates enabled**
  (admin console → DNS → HTTPS Certificates → Enable). Without it the node
  cannot issue a TLS certificate and `tailscale serve` refuses the configuration.
- A reachable Buzz relay
- A Claude subscription (Pro/Max)

## Setup

### 1. Tailscale tag and auth key

In the ACL (`https://login.tailscale.com/admin/acls/file`):

```json
{ "tagOwners": { "tag:claude-box": ["autogroup:admin"] } }
```

Then create an auth key under *Settings → Keys*:

| Option | Value |
|---|---|
| Reusable | **off** — once used, it is burned |
| Ephemeral | **off** — ephemeral nodes disappear when they go offline and invalidate the state in the volume |
| Pre-approved | **on** |
| Tags | `tag:claude-box` |

The tag also keeps the node clear of the 180-day key expiry.

The key is only needed for the first login: `TS_AUTH_ONCE=true` in the Compose
file makes sure `containerboot` does not present it again on every start. After
that the identity lives in the `tailscale-state` volume. You only need a new key
once that volume is lost or the node is deleted in the admin console.

**Clear `TS_AUTHKEY` after the first login** — remove the variable in Coolify.
Coolify passes every variable into the `claude` container as well via `env_file`,
and the agent in there works without asking. That is why the Compose file does
not require the key.

### 2. Buzz identity

At the relay:

```bash
buzz-admin generate-key
buzz-admin add-member --pubkey <agent public key>
```

The secret goes into `BUZZ_PRIVATE_KEY`, your own pubkey into
`BUZZ_ACP_AGENT_OWNER` — the latter is the `owner-only` gate.

### 3. Configuration

```bash
cp .env.example .env
```

Fill in the values, then start:

```bash
docker compose up -d
```

### 4. Login

Once, in the web terminal (see *Access*):

```bash
claude
```

Follow the OAuth flow. The credentials end up in
`/home/dev/.claude/.credentials.json` in the `claude-home` volume and survive
redeploys. The same holds for the global config `.claude.json` (account,
onboarding state): `CLAUDE_CONFIG_DIR=/home/dev/.claude` puts it into the volume
instead of `~/.claude.json`. They serve **both** consumers — the terminal and the
Buzz agent. No `ANTHROPIC_API_KEY` is needed; `buzz-acp` reports `apiType=native`
in its log.

### 5. Agent profile and owner attestation

Buzz treats an identity as an agent only once two owner-backed events exist,
and the order is not optional:

1. **`kind:0` carrying a NIP-OA `auth` tag** — the *marker*. The agent signs
   the profile, the owner signs the tag inside it. From here on the identity
   counts as an agent.
2. **`kind:30177`, `d` tag = agent pubkey** — the *admission*, signed by the
   owner. Only this produces a directory entry, and Buzz accepts the
   coordinate only when its author is the owner attested in the `kind:0`.

With just the first one the identity is marked but listed nowhere — and then
every picker filters it out, as an agent and as a person alike. It is still
reachable by direct message, and nowhere else.

One call does both. It runs on the host, never in the container, because both
private keys are needed:

```bash
tools/enroll-agent.py --agent-name <name> --dry-run    # look first
tools/enroll-agent.py --agent-name <name> --write-env  # then publish
```

It reads the owner key from `BUZZ_OWNER_KEY`, the agent key from
`BUZZ_AGENTS`, the relay from `BUZZ_RELAY_URL`, and `respond_to`,
`respond_to_allowlist` and `parallelism` from the front matter of
`agents/<name>.md`. An existing profile is fetched first, so `about` and
`picture` survive.

`--write-env` also records `BUZZ_AUTH_TAGS=<name>=<signature>`. The running
agent needs that so its *later* events carry the tag as well — run
`docker compose up -d` once afterwards.

Verification steps and pitfalls: [`tools/README.md`](tools/README.md).

### 6. GitHub access (optional)

The agent clones and pushes over HTTPS with a **fine-grained token**, not over
SSH. One token covers several repositories and can be extended later; deploy keys
apply per repository and cannot be extended.

Create the token under *Settings → Developer settings → Personal access tokens →
Fine-grained*, then put it in the environment:

```
GITHUB_TOKEN=github_pat_...
GIT_USER_NAME=Tuatara
GIT_USER_EMAIL=...
```

The token is **never written to disk**. A credential helper
(`git-credential-github-token`) serves it from the process environment; neither
`.gitconfig` nor `.git-credentials` contains it. The test proves this.

If the variable is missing, the helper stays silent and the container starts
normally.

#### Repositories under several owners

A fine-grained token is always valid for **one** resource owner — personal *or*
organisation, never both. If you work on repositories under several owners you
need several tokens and map them in **one** variable:

```
GITHUB_TOKENS=alice=github_pat_xxx,ExampleOrg=github_pat_yyy
GITHUB_TOKEN=                 # optional fallback for everything else
```

The owner is the first path segment of the repository URL; case does not matter.

A single variable rather than `GITHUB_TOKEN_<OWNER>`, because Compose and the
Coolify UI have to pass every variable through **by name** — another owner would
otherwise be a change to the Compose file instead of a change to the
configuration.

For the mapping to take effect, `credential.useHttpPath` is set: Git then passes
the path to the helper, not just the host. Without it the helper would only ever
see `github.com`.

### 7. Agents

Which agents run is defined in [`agents/`](agents/) — one Markdown file per
agent, with frontmatter for the configuration and the system prompt below it. The
private keys live separately from that, in the environment:

```
BUZZ_AGENTS=tuatara=<privkey>,gecko=<privkey>
```

[`agents/AGENT_NAME.md`](agents/AGENT_NAME.md) is the **template**, not a
running agent. Copy it to `agents/<name>.md`, replace the `{{AGENT_NAME}}` and
`{{BUZZ_RELAY_IDENTIFIER}}` placeholders and add the name to `BUZZ_AGENTS`. The
renderer only ever reads the names from that variable — a file not listed there
never becomes a process, so the template sits there without effect.

A further agent is therefore one file plus one entry — no change to
`docker-compose.yml` or `supervisord.conf`. Every frontmatter key becomes the
`BUZZ_ACP_*` variable of the same name, so future options of `buzz-acp` are
usable without a code change.

**One worker costs roughly 640 MB.** `parallelism` multiplies that. The
entrypoint adds it up at start and warns before memory runs short.

Details in [`agents/README.md`](agents/README.md).

### 8. Skills

Three ways, and they do not exclude each other:

| Way | Where | When |
|---|---|---|
| Project skill | `.claude/skills/` in the cloned repository | repository-specific, comes along automatically |
| Container skill | `skills/` in this repository | applies to every agent, versioned |
| Runtime skill | `~/.claude/skills/` in the web terminal | for trying things out |

The entrypoint mirrors `skills/` into the volume at start. It **only copies in
and deletes nothing** — a skill created at runtime therefore survives; on a name
clash the repository wins.

Working only in the volume is not enough: a redeploy with a fresh volume takes
such skills along **silently**. The agent reports nothing, it just behaves
differently from then on. Try things out in the volume by all means, put anything
permanent into the repository.

Details in [`skills/README.md`](skills/README.md).

**Plugins** live in `plugins.txt`, one line per plugin with the source of its
marketplace:

```
superpowers@claude-plugins-official  anthropics/claude-plugins-official
```

The entrypoint installs them as `dev` into the volume on every start, in the
background — terminal and agent do not wait for the network. An already installed
plugin is only confirmed; only the very first start takes a few seconds until it
is there. Superpowers belongs here deliberately and not in `skills/`: it brings a
SessionStart hook with it, and its skills call each other as
`superpowers:<skill>` — both are missing if only the skill files are copied.
Claude Code pulls updates from the marketplace.

If an installation fails, for instance without network, the start reports a
`WARNUNG: Plugin …` and carries on. A deleted line uninstalls nothing: use
`claude plugin uninstall <plugin>@<marketplace>` in the terminal for that.

### 9. SSH for the IDE (optional)

So that an IDE can edit `/workspace`, an `sshd` runs in the container — bound to
`127.0.0.1`, handed into the tailnet through the TCP forwarder in
`docker/serve.json`. **No port is opened on the host**; the guarantee is the same
as for the web terminal, just a second service behind the same boundary.

```
SSH_AUTHORIZED_KEYS=ssh-ed25519 AAAA...;ssh-ed25519 AAAA...
```

Separate several keys with `;`. If the variable is empty, `sshd` stays off and
only the web terminal runs — a forgotten variable does not cost you the entire
access.

```bash
ssh dev@<TS_HOSTNAME>.<tailnet>.ts.net
```

In **VS Code**: *Remote-SSH: Connect to Host* with the same address.

In **Zed**: `ctrl-cmd-shift-o` → *Connect New Server*, or directly in
`~/.config/zed/settings.json`:

```json
{
  "ssh_connections": [
    {
      "host": "claude-box-dev.<tailnet>.ts.net",
      "username": "dev",
      "args": ["-i", "~/.ssh/claude-box"],
      "nickname": "claude-box",
      "projects": [{ "paths": ["/workspace"] }]
    }
  ]
}
```

In **Antigravity**: *Remote Explorer* → `claude-box-dev`.

The open dialog starts in the home directory. Only hidden directories live there,
so the container looks empty — which is why the entrypoint creates `~/workspace`
as a symlink to `/workspace`.

All three install a server component in the container (`~/.vscode-server`,
`~/.zed_server`, `~/.antigravity-ide-server`). There is one volume for each,
otherwise it downloads again after every redeploy.

**`wget` has to stay in the image.** Antigravity's installer downloads its server
with it and nothing else, and otherwise aborts with `Error need wget to download
server binary` — a message that looks like a network problem but is not one.

Key authentication only, no password, no root, only the user `dev`. The host keys
live in the `ssh-hostkeys` volume — without it every redeploy generated new ones
and the client warned about a changed host key every time. A warning like that
wears off until you ignore a real one.

### 10. Packages and cron

Which additional apt packages live in the container is defined in
`packages.txt` — one line per package, comments and blank lines allowed.
Currently in there:

| Group | Packages |
|---|---|
| Services | `cron`, `tzdata` |
| Tools | `jq`, `unzip`, `rsync`, `git-lfs`, `sqlite3` |
| Network diagnostics | `iputils-ping`, `dnsutils` (`dig`), `netcat-openbsd` (`nc`) |
| Toolchains | `php-cli`, `composer`, `python3-pip`, `python3-venv`, `imagemagick`, `ffmpeg` |

`ffmpeg` is the largest of these and accounts for the lion's share of the image
size. Delete the line if you do not need it.

`gh` and `uv` do **not** go through this list: one needs its own apt source, the
other an installer script. Either would be a line in the Dockerfile.

The Dockerfile installs them in its **last** layer. A change to the list
therefore only rebuilds that step, not the `npm install` above it. What the
container itself needs (`tmux`, `supervisor`, `openssh-server`, `git`,
`ripgrep`, `wget`) stays in the Dockerfile — that is not a choice, it is a
prerequisite.

`test/image.sh` checks every line of the list against the finished image: if a
package is listed, its binary has to be there.

**`cron` is a special case.** If it is in the list, the entrypoint additionally
starts the service — a crontab without a running `cron` never fires, and that
goes unnoticed for a long time. Create crontabs as `dev`:

```bash
crontab -e
crontab -l
```

They live in the `cron-spool` volume and survive redeploys. Without that volume
they would be silently gone after every deployment. A job's output ends up in the
container log, because `cron` runs in the foreground.

**The timezone is part of this.** `TZ` is set to `Europe/Berlin` in
`docker-compose.yml` and can be overridden through the environment. Without
`tzdata` **and** without `TZ` the container would run in UTC — a crontab set to
8 a.m. would fire at 10 in summer. `test/compose.sh` checks that `TZ` is set,
`test/image.sh` that the zone resolves in the image.

`TZ` alone is not enough for that, though: it only takes effect in processes
that inherit the environment. **cron schedules by the system timezone**, and in
the image that was UTC. The entrypoint therefore sets `/etc/localtime` and
`/etc/timezone` from `TZ`. Before that, everything looked right in the terminal
while crontabs fired two hours off — exactly the kind of bug you notice weeks
later.

#### What a cron job sees — and what it does not

cron starts jobs with an **empty environment**. That is the most common reason
for jobs that silently do nothing:

| | There? | Where from |
|---|---|---|
| `TZ`, `CLAUDE_CONFIG_DIR` | yes | The entrypoint writes them to `/etc/environment`, which cron reads via `pam_env`. |
| `PATH` | only `/usr/bin:/bin` | cron sets it itself. `claude`, `buzz` and `agent-watch` live in `/usr/local/bin` — so use absolute paths or put a `PATH=` line at the top of the crontab. |
| `BUZZ_*`, `GITHUB_*` | **no** | Secrets only exist in supervisord's process environment. A job that needs them has to be given them. |

For the last point there is a switch. `CRON_SECRETS=1` makes the entrypoint
write one file per agent:

```
/run/buzz/<agent>.env      # 0640 root:dev, directory 0750 root:dev
BUZZ_RELAY_URL=…
BUZZ_PRIVATE_KEY=…
BUZZ_AUTH_TAG=…            # only with an entry in BUZZ_AUTH_TAGS
```

Load it in the job with `set -a; . /run/buzz/<agent>.env; set +a`. `/run/buzz`
is pure RAM via `tmpfs` in `docker-compose.yml` — without that entry `/run`
would be the overlay filesystem, so the key would sit written on disk. The
entrypoint sets the permissions, because a `tmpfs` would otherwise arrive as
`1777`.

**This is deliberately a switch and not a default.** With it, the key sits
readable in the container's filesystem, which departs from the promise under
*Security* that secrets only live in the process environment. Without the
switch the file does not exist; `test/image.sh` checks both directions,
including the counter-test that a third user in the container cannot reach it.

Not into `/etc/environment` — that file is readable by everyone. Only `TZ` and
`CLAUDE_CONFIG_DIR` go there, and a test pins that down.

**Limit:** a cron job can send messages, but it cannot wake the agent — a
message from the agent to itself triggers nothing. For work on a schedule
("write the report every Monday") the job has to start its own Claude session,
e.g. `claude -p '<task>'`. `CLAUDE_CONFIG_DIR` in `/etc/environment` is the
prerequisite for that, otherwise Claude would not find the login in the volume.
**Untested.**

## Access

```
https://<TS_HOSTNAME>.<tailnet>.ts.net
```

A `tmux` session named `main` — the tab may be closed, the session keeps running.
There is **no password**: the access control is tailnet membership plus the ACL.

## Security

**What holds structurally:**

- No `ports:` block. Nothing is published on the host.
- No `/var/run/docker.sock`. The socket would effectively be root on the host and
  would give up, in an inconspicuous place, exactly the isolation this stack is
  built for. Project toolchains belong in the image, services as services next to
  it.
- Processes run as `dev` (uid 1000), not as root.

**What you have to set yourself:**

- **Restrict the Tailscale ACL** to your own devices. Tailnet membership alone is
  not a boundary once the tailnet is shared.
- **`--max-turn-duration`** in `docker/supervisord.conf`. The default of 7200
  seconds is generous for an unattended agent and is the only brake against an
  agent that gets stuck.

**What you should know:**

`buzz-acp` starts the agent with `permission_mode=bypassPermissions` — that is
the harness default. The agent does not ask before it writes. In this container
that is defensible, but it is a property, not a detail.

`--respond-to owner-only` is set. Only the pubkey stored in
`BUZZ_ACP_AGENT_OWNER` can trigger the agent.

## Deploying on Coolify

Resource type **Docker Compose**, pointing at this repository.

`.github/workflows/tests.yml` runs `test/compose.sh` and `test/image.sh` on
every push and pull request. It deliberately **does not deploy** — this
repository ships without a rollout step, so a fork never carries someone else's
deploy target.

If you want the tests to gate your own rollout, add a job that runs after
`tests` and calls your Coolify deploy webhook. Then turn **Automatic Deployment
off** in Coolify: it does not see the test runs and would otherwise roll out on
push itself, without waiting for them.

**Assign no domain and expose no ports** — otherwise the Coolify proxy creates a
public entry and the whole point is gone.

The variables go into the Coolify UI, not into the repository as an `.env`. Three
of them have to differ from the local stack:

| Variable | In production |
|---|---|
| `TS_HOSTNAME` | its own name, e.g. `claude-box` — otherwise the node state collides with the local instance |
| `TS_AUTHKEY` | a **new** key for the first login; clear it afterwards |
| `BUZZ_PRIVATE_KEY` | its own keypair, otherwise two agents answer the same `@mention` |

`BUZZ_RELAY_URL` and `BUZZ_ACP_AGENT_OWNER` stay the same.

On an amd64 host the image builds without emulation and therefore considerably
faster than locally on Apple silicon.

Coolify handles `network_mode: "service:tailscale"`: its Compose parser omits the
`networks:` block it otherwise injects on such a service.

**No bind mounts out of the repository.** For a relative path like
`./docker/serve.json` Coolify does not put down the file from the checkout but an
empty **directory** under `/data/coolify/applications/<uuid>/`. That is why
`serve.json` sits in the sidecar image (`docker/tailscale.Dockerfile`), and
`test/compose.sh` fails as soon as a bind mount turns up again. An earlier
deployment leaves the directory behind on the host; it is no longer used and can
go.

The symptom was inconspicuous: `containerboot` reads the serve configuration only
after login, exits on the directory and restarts — and `claude` is left behind in
the old namespace without network (see *Never restart the Tailscale container on
its own*). `buzz-acp` then only reports `Temporary failure in name resolution`.

**Coolify passes every variable into every container.** It adds `env_file: .env`
to each service. For the sidecar that means `TS_HOSTNAME` is always in its
environment, and `containerboot` makes `--hostname` out of it itself. A second
`--hostname` in `TS_EXTRA_ARGS` makes `tailscale up` abort with `flag provided
multiple times`. That is why the name is set only through `TS_HOSTNAME`. Coolify
deletes containers after several restarts; the log tab then only says `No such
container`.

**Manage build arguments manually.** Under *Advanced → Build arguments* choose
"Managed manually in Dockerfile". Otherwise Coolify writes an `ARG` line into
both Dockerfiles for every variable before each build — including `TS_AUTHKEY`,
`BUZZ_PRIVATE_KEY` and the GitHub tokens — and passes the values with
`--build-arg`. Neither image needs build arguments. That rewriting step has also
already aborted with exit code 255 without any message and taken the deployment
down with it.

## Tests

```bash
./test/compose.sh  # 11 assertions against the Compose file and the sidecar image
./test/image.sh    # 122 assertions against the image
./test/stack.sh    # 17 assertions against the running stack
```

`test/compose.sh` needs neither `.env` nor a tailnet and proves that no service
hangs off a host path.

`compose.sh` and `image.sh` run in the GitHub Action on every push.
`stack.sh` does not: it needs an auth key and registered a new node in the tailnet
on every run.

**What counts is the run in the Action, not the one on the Mac.** Docker Desktop
does not enforce permissions and ownership in mounted host directories, Linux
does. Both directions have happened: a test was green locally and red on the
runner because a process running as `dev` could not write into the folder — and
the assertion "restored config belongs to dev" is red locally (`600 root`) and
green on the runner the other way round.

`test/stack.sh` proves, among other things, that the `claude` container hangs off
the network namespace of `tailscale`, that no port is published on the host, and
that `ttyd` is not reachable from the host.

## Operating it

### Watching the agent

The Buzz agent runs without a terminal: supervisord starts `buzz-acp`, and that
drives `claude-agent-acp` in the background. It therefore does not show up in the
tmux session of the web terminal. You can still read along — in a second tmux
window (`ctrl+b c`, back with `ctrl+b n`):

```bash
agent-watch
```

```
=== Session 1ae3324a-….jsonl ===

[Eingang] <buzz-event type="@mention"> … Content: @Tuatara please check the build …

[Claude] I will look at the last run first.
  -> Bash: git log --oneline -5
     ok
```

`agent-watch` reads the transcript every turn leaves behind under
`~/.claude/projects/`. It shows the last 40 entries of the newest agent session,
follows it live and switches as soon as the agent writes in a different session —
after `idle_timeout`, say, or in a different channel. If there is none yet, it
waits. Your own terminal sessions live in the same directory and are skipped:
agent sessions carry `"entrypoint": "sdk-ts"`.

It only reads. Opening an agent session with `claude --resume` would be a bad
idea — every input there lands in the very session the agent is working in.

### Never restart the Tailscale container on its own

The `tailscale` service **owns the network namespace**; `claude` joins it through
`network_mode: "service:tailscale"`. A `docker compose restart tailscale` creates
a new namespace that `claude` is no longer attached to — and it does so **without
being noticeable**: both containers keep running, `ttyd` and `sshd` keep
listening, only Tailscale no longer reaches them. From the outside it looks as if
the service is dead.

The right way is:

```bash
docker compose restart tailscale
docker compose restart claude     # must follow
```

A plain restart is enough — the container joins the *current* namespace at start,
a `--force-recreate` is not needed.

`test/stack.sh` checks this: comparing container IDs alone is not enough, because
that stays the same across a restart. What is checked instead is whether the
`tailscale` container actually reaches the services of `claude` on `127.0.0.1`.

## Pitfalls

- **The Tailscale sidecar must not be pinned to `linux/amd64`.** Under Rosetta
  the login to the control plane fails with
  `chacha20poly1305: message authentication failed`. Only our own image needs
  amd64, because of the Buzz binaries.
- **`docker compose down -v` deletes the Tailscale identity** and the Claude
  login. Use `down` without `-v` for restarts; otherwise you need a new auth key
  and a new OAuth login.
- **Claude wants to be set up again after every redeploy**, although the
  credentials are in the volume: then `CLAUDE_CONFIG_DIR` is missing in that
  session, and the config lands in the ephemeral `~/.claude.json` again. It is set
  in the image, and for SSH through `SetEnv` in `docker/sshd_config`. Whoever
  starts Claude by some other route has to pass it themselves. If `.claude.json`
  is missing from the volume at start, the entrypoint restores the newest backup
  with an account from `~/.claude/backups`.
- **The `buzz-cli` skill lives under `/opt/buzz-skills`**, not directly under
  `/home/dev/.buzz`. A volume hangs there that would hide image content; the
  entrypoint mirrors it in on every start. `buzz-acp` does not roll it out itself
  — locally that is done by the desktop app, which does not exist here.
- **Locally on Apple silicon** the image runs under emulation. That is fine for
  smoke tests, but the build takes noticeably longer.

## License

[MIT](LICENSE) — © 2026 Bastian Strauss, WUS Solutions.

Use it, change it, run it commercially. The one condition is that the copyright
notice and the licence text travel with every copy and every substantial portion
of the code.
