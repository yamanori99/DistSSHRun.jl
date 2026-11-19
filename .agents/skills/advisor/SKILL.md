---
name: advisor
description: A second opinion in this agent, only when the user asks.
disable-model-invocation: true
---

# Advisor

Do not enable this on your own. Do not spawn a subagent. Do not write `.cursor/advisor/`.

When the user asks for a second opinion, answer it in this agent. Give the request, what you already decided, the evidence, and the options. Then say whether you would proceed, proceed with a named change, or stop. You remain accountable for the result.

Consult only at a real fork: a hard-to-reverse choice, the same failure after two genuine attempts, or before you declare a large change done. Skip a typo or a one-line edit and say so. Do not loop.

Copyright (c) 2026 Cursor. SPDX-License-Identifier: MIT
