import { before_agent_start } from "./hooks";

const lastOrientationAt = new Map();

export * from "openclaw";

before_agent_start((event) => {
  const now = Date.now();
  const lastRun = lastOrientationAt.get(event.sessionKey) || 0;

  if (now - lastRun < 300000) {
    console.log("Skipping orientation (cooldown)");
    return;
  }

  if (event.messageCount === -1 || event.prevCount === -1) {
    console.log("Skipping orientation (invalid signal)");
    return;
  }

  lastOrientationAt.set(event.sessionKey, now);
});
