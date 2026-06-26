# Agent Node Join Test Archive

This file is an archive note, not an operational runbook.

The current supported multi-host agent workflow is documented in
[`deploy/production/README.md`](../deploy/production/README.md#multi-host-agent-nodes).
Use that guide for `myapp-ctl agent-node add`, `join`, `ls`, `pause`,
`resume`, and capacity changes.

## Verified Conclusion

- Pull-mode agent nodes can join a master backend with outbound-only access.
- The generated join flow is a single `myapp-ctl agent-node join ...` command,
  not a self-writing bootstrap script.
- Pull-mode nodes self-register through backend acquire heartbeats; they do not
  rely on the old host-level `myapp-agent-register.timer`.
- `myapp-ctl agent-node ls` is the cluster view.
- `myapp-ctl agent ls` is intentionally local-only and shows current active
  runtime containers on the host where it runs.

## Current Test Shape

For a clean validation, use two real generation requests:

1. Pause every node except the target node.
2. Submit a short authenticated `/api/ai/chat/start` request with
   `provider=deepseek` and `agent=claude`.
3. Confirm `myapp-ctl agent ls` on the target host shows the session while it is
   running.
4. Confirm `/api/ai/chat/<session>/result` ends with `status=done` and a
   `json_app_ready` client action.
5. Resume all paused nodes.

Do not commit generated join commands or logs containing registration tokens.
