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
