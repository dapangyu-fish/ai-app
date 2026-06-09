"""AI provider registry package.

Provider definitions live under provider/agent adapter directories so each
supplier's Claude/Codex/OpenCode differences stay close to the relevant config.
Only non-secret defaults belong here; tokens are always read from env.
"""

