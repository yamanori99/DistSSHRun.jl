---
name: advisor
description: A second opinion in this agent. Slash command only.
disable-model-invocation: true
---

# Advisor

Start only when the user explicitly invoked this skill with its slash command. Do not start from a task that merely seems to match. Do not enable this on your own. Do not spawn a subagent. Do not write `.cursor/advisor/`.

Answer in this agent. Give the request, what you already decided, the evidence, and the options. Then say whether you would proceed, proceed with a named change, or stop. You remain accountable for the result.

Consult only at a real fork: a hard-to-reverse choice, the same failure after two genuine attempts, or before you declare a large change done. Skip a typo or a one-line edit and say so. Do not loop.

Copyright (c) 2026 Cursor. SPDX-License-Identifier: MIT
