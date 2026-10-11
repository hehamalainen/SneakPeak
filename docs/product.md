# The mission

Let a person supervise one agent or a team without becoming a full-time window switcher. A peek should answer three questions in a few seconds:

1. Where is this mission meant to land?
2. What concrete evidence has changed since the last checkpoint?
3. What decision needs my attention, and what happens after I answer?

The notch is a delivery surface. The product is a trustworthy handoff between autonomous work and human judgment.

## Interaction

At rest, a small row of lights and a short phrase gives permission to stay focused. Blue means observed work; green means a turn has finished; amber means an explicit intervention or course risk. Quiet or disconnected agents become muted. Color is always accompanied by text in the expanded view.

Hover reveals the mission outcome, the team, a readable account of the current work, progress evidence, and the next checkpoint. Explicit decisions sort first. The destination view shows observable checks separately from activity. It should never require the person to read a tool transcript to understand why they are needed.

A connected permission displays the complete scope and sends a one-step response. Other intervention types hand the person back to the original session. Expiry and disconnection remain visible. Silence is not assent.

## Trust rules

- A working light does not prove progress.
- A finished turn does not prove the mission is finished.
- Agent-reported evidence is labeled as reported until a person checks it.
- An explicit course risk is actionable; missing evidence is uncertainty.
- A sent decision stays pending until the host acknowledges it.
- Example agents are always identified as examples.
- Observation never changes another agent's permissions.

## What should come next

Validate this version during a real long-running build. Look for missed decisions, noisy status changes, unclear summaries, and cases where a person cannot tell whether the work still serves the goal.

The next substantive feature is periodic mission checkpoints from connected agents: outcome achieved so far, evidence, remaining uncertainty, and the smallest human decision needed. After those checkpoints are reliable, a semantic course review can compare them against the explicit landing checks, explain its basis, and remain visibly distinct from a verified result. Add remote/team transports only after that loop earns trust.
