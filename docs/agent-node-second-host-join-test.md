# Agent Node Second Host Join Test

Date: 2026-06-05
Branch: `feat/agent-control-plane`

## Hosts

- Master backend: `77.237.233.229`
- Second agent host: `103.233.254.179`
- Target node id: `myapp-agent-103-233-254-179`
- Mode: pull runner, provider mode `master`

## Goal

Validate that a second physical agent host can join the 77 test cluster with
outbound-only connectivity, then pull AI jobs through the backend without the
backend opening an inbound connection to the agent host.

## First Attempt Notes

1. Updated 103 `/root/ai-app` to branch `feat/agent-control-plane` and installed
   `myapp-ctl`.
2. Generated the old `agent-node add` bootstrap output on 77 and copied it to
   103.
3. Direct `scp` from 77 to 103 failed with `Connection closed`; copying through
   the operator machine worked.
4. The old bootstrap output was a heredoc wrapper that wrote
   `/root/myapp-agent-bootstrap.sh`. Running it once only materialized the inner
   script, which was confusing and not an acceptable join flow.
5. Running the inner script then failed at image pull:
   Docker mirror `docker.xuanyuan.me` returned `429 Too Many Requests` for
   `dapangyufish/myapp-agent-runtime:agent-control-plane`.

## Fixes Made

The branch now adds a real join flow:

- `myapp-ctl agent-node add` prints a single `myapp-ctl agent-node join ...`
  command instead of a self-writing shell script.
- `myapp-ctl agent-node join` runs on the new agent host and handles local
  config, agent secrets, deploy, register timer, and immediate status checks.
- Join supports explicit image strategies:
  no image flag requires images to exist locally, `--pull` pulls images, and
  `--build` builds images locally.
- Pull-mode nodes no longer install or rely on the old host
  `myapp-agent-register.timer`; the agent-node container self-registers through
  backend acquire heartbeats.
- Join writes explicit `AGENT_NODE_LABELS`, including `host=...`, so stale
  local `PUBLIC_HOST` values cannot make the master display the wrong machine.
- Missing old timer cleanup is silent and idempotent; first-time hosts no
  longer print a false `Failed to disable unit` warning.

## 103 Environment Notes

- Initial free disk on `/`: about 4.4G.
- Old unrelated test images and a stale `jsonapp-postgres` container were
  present from previous experiments.
- Removed the stale container and ran Docker prune for unused objects only,
  preserving `/mnt/myapp`. Free disk increased to about 11G.
- Because the configured Docker mirror returned 429, the latest agent images
  were streamed from 77 with `docker save | gzip | ssh ... docker load`.

## Retry Standard

The retry is considered smooth only when:

- Both 77 and 103 are on branch `feat/agent-control-plane`.
- 77 `agent-node add` outputs a direct `myapp-ctl agent-node join ...` command.
- 103 can run that command without manual script editing.
- 77 `myapp-ctl agent-node ls` shows both nodes online.
- A test AI request is pulled by the 103 node and returns a normal terminal
  backend status.
- `myapp-ctl agent ls` on each host only shows its local active containers.

## Final Verified Flow

Both hosts were updated to branch `feat/agent-control-plane` at commit
`8b3dc5f`.

On the master host, generate the join command:

```bash
myapp-ctl agent-node add \
  --backend http://77.237.233.229:5566 \
  --host 103.233.254.179 \
  --node-id myapp-agent-103-233-254-179 \
  --capacity 1 \
  --mode pull \
  --provider-mode master
```

Copy the single printed command to the second host and run it. For unattended
testing, the same command can be piped directly:

```bash
ssh root@77.237.233.229 \
  'myapp-ctl agent-node add --backend http://77.237.233.229:5566 --host 103.233.254.179 --node-id myapp-agent-103-233-254-179 --capacity 1 --mode pull --provider-mode master | tail -n 1' \
  | ssh -p 22 root@103.233.254.179 'bash -s'
```

The generated command contains registration tokens and must not be committed or
posted in logs.

Final status on the master:

```text
agent nodes: total=2 online=2 pending=0 down=0 stale=0 active_runs=0 capacity=2
myapp-agent-103-233-254-179  host=103.233.254.179  online  cap=1  key_src=master  url=pull://myapp-agent-103-233-254-179
myapp-prod-77-237-233-229    host=77.237.233.229   online  cap=1  key_src=master  url=pull://myapp-prod-77-237-233-229
```

Final status on 103:

```text
agent-node compose running health ok
active agent runs: 0
no /root/myapp-agent-bootstrap.sh
myapp-agent-register.timer inactive
AGENT_NODE_LABELS=host=103.233.254.179,provider_mode=master,mode=pull
```

To prove scheduling, 77 local `myapp-agent-node` was temporarily stopped and
its registry row removed. A short AI request with session
`caab715d-c10b-43a2-94cc-a1e9117d3d67` was then submitted through the 77
backend. The 103 host created the Claude state directory for that session and
its run log ended with `status=done returncode=0`. The 77 local agent-node was
then restarted, returning the cluster to two online nodes.
