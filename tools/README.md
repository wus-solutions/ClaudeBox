# Host tools

*Deutsche Fassung: [README.de.md](README.de.md)*

Three scripts that run on the **host**, never inside the container: they need
the owner's private key, and that belongs neither in an image nor in a
container environment. Plain Python 3.9 or newer (the system Python on macOS is
enough), no dependencies, no Docker.

| Script | What for |
|---|---|
| **`enroll-agent.py`** | **the usual path:** attestation, profile and policy in one run |
| `mint-auth-tag.py` | sign the NIP-OA attestation only → `BUZZ_AUTH_TAGS` |
| `publish-agent-policy.py` | publish the owner policy `kind:30177` only |

The lower two are the building blocks and stay useful on their own — renaming an
agent without touching its profile, for instance. `enroll-agent.py` loads them
as modules; all three files must sit next to each other so that signing, key
parsing and relay access exist exactly once, each with its own self-test.

---

## Why it takes two proofs

This is where the setup used to get stuck. "Agent" is not an account type in
Buzz; it is a chain of evidence made of several events. Two of them count for
the desktop app:

**1. `kind:0` with a NIP-OA `auth` tag** — signed by the owner, published by the
agent. This is the *marker*: from here on the identity counts as an agent. In
the Buzz source it is literally one line
(`desktop/src-tauri/src/nostr_convert/user_search.rs`):

```rust
is_agent: owner_pubkey.is_some(),   // owner_pubkey == valid auth tag in kind:0
```

**2. `kind:30177`, signed by the owner, `d` tag = agent pubkey** — the
*admission*. The desktop app builds its agent directory from owner-signed 30177
coordinates and relay-signed `kind:39002` member lists
(`desktop/src-tauri/src/commands/agent_discovery/relay_directory.rs`).

Step 1 on its own is the worst of both worlds: the identity is marked as an
agent but appears in no directory — and **every** picker in the desktop app
filters out marked agents that are not admitted. Selectable neither as an agent
nor as an ordinary participant:

- add member → `desktop/src/features/channels/ui/MembersSidebar.tsx`
- `@` mention → `desktop/src/features/messages/lib/buildMentionCandidates.ts`
- new message / DM → `desktop/src/features/messages/ui/useNewMessageRecipients.ts`

Once the 30177 is there, the directory's `retain` matches on *owner == me*, the
agent is found **even without** channel membership, and the app offers the
invite dialog that adds it as a bot member.

**Why a separate script.** There is no `buzz` command for the 30177.
`buzz agents draft-create` only sends a draft to the desktop form and creates a
*new* key there; the app does not adopt an existing container key. Otherwise
this coordinate is written exclusively by Buzz Desktop when it creates a managed
agent of its own.

---

## Setting up an agent

Assumed: identity created, admitted on the relay, entry in `BUZZ_AGENTS`,
`agents/<name>.md` in place, container running (see
[README.md](../README.md), sections 2–5). Your own private key is in the `.env`
as `BUZZ_OWNER_KEY` — it is never passed into the container.

### 1. Enrol — one call

```bash
tools/enroll-agent.py --agent-name <name> --dry-run    # look first
tools/enroll-agent.py --agent-name <name> --write-env  # then publish
```

The script collects everything itself: owner key from `BUZZ_OWNER_KEY`, agent
key from `BUZZ_AGENTS`, relay from `BUZZ_RELAY_URL`, and `respond_to`,
`respond_to_allowlist` and `parallelism` from the front matter of
`agents/<name>.md`. It then signs the attestation, fetches the existing `kind:0`
from the relay, appends the `auth` tag, publishes it with the **agent's** key —
and the policy with yours.

The order is not cosmetic: the desktop app accepts the coordinate only if the
profile already attests the owner.

Three mistakes that kept happening by hand are now impossible:

- **`about` and the picture survive.** `buzz users set-profile --name X` without
  `--about` clears the field.
- **Exactly one `auth` tag.** Two are worse than none — NIP-OA discards both.
- **`respond_to` cannot drift**, because policy and front matter come from the
  same source.

`--write-env` records `BUZZ_AUTH_TAGS=<name>=<signature>` in the `.env`,
replacing only this agent's entry; without the flag the line is merely printed.
It is needed so that **later** events of the running agent carry the tag too —
run `docker compose up -d` once afterwards.

None of this needs the container any more. The profile part used to run inside
it as `buzz users set-profile`, with a redeploy beforehand so that
`BUZZ_AUTH_TAG` was in the environment.

### 2. Renew the policy only — renaming

`kind:30177` is replaceable per NIP-33: publishing the same coordinate again
overwrites the previous version without touching the profile. `--respond-to`
and `--allow` must match the front matter in `agents/<name>.md`:

```bash
grep -E '^BUZZ_OWNER_KEY=' .env | cut -d= -f2- | \
tools/publish-agent-policy.py --owner-stdin \
  --agent <agent-pubkey> \
  --name "<Name>" \
  --respond-to allowlist --allow <owner-pubkey> \
  --relay "$BUZZ_RELAY_URL" \
  --dry-run
```

`--owner-stdin` instead of `--owner <key>`: arguments sit in the process list
while the command runs and easily end up in the shell history. At a terminal the
script asks for the key without echoing it; in a pipe it reads the first line.
`mint-auth-tag.py` still takes the key as an argument only — the same caveat
applies there.

Without `--dry-run` the event is signed and sent to the relay via `POST /events`
with a NIP-98 header. `--relay` accepts `https://` or `wss://` and may come from
`BUZZ_RELAY_URL`. `--selftest` checks signing, event id and header shape without
a network — against the signed example event from `docs/nips/NIP-OA.md` in the
Buzz repository, that is, against a source other than the script itself.

### 3. Check both at once

One command checks policy **and** attestation. It runs in the container because
`--owner me` resolves there via `BUZZ_AUTH_TAG`; a `buzz` on the host is not
needed:

```bash
docker compose exec claude buzz users get --name "<Name>" --owner me
```

The search runs over the owner's kind:30177 events and takes the name from their
content. **An empty result means the policy is missing or carries a different
name** — before that, this command is not a meaningful test. With the policy in
place, the `verification` field tells you about the `kind:0`:

| Value | Meaning |
|---|---|
| `verified` | correct — `owned_by_me: true` should appear as well |
| `missing_auth` | no `auth` tag in the `kind:0` → run the enrolment again |
| `missing_profile` | no `kind:0` for this key at all |
| `owner_mismatch` | signed with the wrong key (agent instead of owner?) |
| `condition_mismatch` | conditions in the tag do not apply to a `kind:0` → use empty conditions, as the scripts do |
| `multiple_auth_tags` | two `auth` tags in the profile — one is always wrong, Buzz discards both |

### 4. Add it to channels

After reloading the desktop app the agent is back in the member picker and under
Agents. Alternatively from the CLI with the owner key:

```bash
buzz channels add-member --channel <uuid> --pubkey <agent-pubkey> --role bot
```

The `bot` role is not cosmetic: the directory checks the fourth position of the
`p` tag in the relay-signed member list for `bot`
(`desktop/src-tauri/src/nostr_convert/agent_directory.rs`). The green dot comes
from `buzz-acp` itself afterwards (`kind:20001` presence); nothing to do for
that.

---

## Pitfalls

**`respond_to` lives in two places and must agree.** The front matter in
`agents/<name>.md` decides who the agent *answers* (it becomes
`BUZZ_ACP_RESPOND_TO`). The 30177 decides who may *select* it. If they diverge,
the UI shows the agent and it stays silent — or the other way round.
`enroll-agent.py` reads both from the front matter and therefore cannot drift;
anyone using `publish-agent-policy.py` on its own has to keep it in mind.

**`nobody` cannot be expressed.** The policy only knows `owner-only`,
`allowlist` and `anyone`. An agent with `respond_to: nobody` in its front matter
(heartbeat operation) gets no meaningful policy; publish `owner-only` instead,
or leave the policy out.

**Required fields are required.** `name`, `parallelism` and `respond_to` must be
present in the content; if one is missing, the desktop app discards the
coordinate **silently** and the agent is invisible again. The scripts always
write all three.

**An invalid latest policy is worse than none.** The coordinate stays occupied
and cannot fall back to an earlier state. Hence `--dry-run` first.

**The event is world-readable.** Its content holds the display name, the
parallelism and the response policy — no prompts, no keys, no tokens. Keep it
that way.

**Re-running is how you change things.** `kind:30177` is a parameterised
replaceable event (NIP-33): publishing the same coordinate
`(owner, 30177, agent)` again overwrites the previous version.

**The owner key stays on the host.** All three scripts deliberately run outside
the container.

---

## Sources

The sections above point at files in the Buzz repository
(`github.com/block/buzz`). The specifications behind them:

- `docs/nips/NIP-OA.md` — owner attestation, the `auth` tag
- `docs/nips/NIP-AP.md` — agent personas, `kind:30175`/`30177`
- `docs/owned-agent-discovery.md` — how the directory verifies ownership
- `docs/agent-management-provenance.md` — why externally operated agents are
  marked as "not managed on this device"
