import { randomUUID } from "node:crypto";

const baseUrl = (process.argv[2] || "http://127.0.0.1:8787").replace(/\/$/, "");
const count = Number.parseInt(process.argv[3] || "96", 10);

if (!Number.isInteger(count) || count < 1 || count > 2000) {
  throw new Error("count must be an integer between 1 and 2000");
}

const body = JSON.stringify({
  model: "qwen3.8-max-preview",
  max_tokens: 1,
  messages: [{ role: "user", content: "RATE_LIMIT_PROBE" }],
});
const probeKey = `headroom-rate-limit-probe-${randomUUID()}`;

const send = async () => {
  try {
    const response = await fetch(`${baseUrl}/v1/messages`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": probeKey,
        "anthropic-version": "2023-06-01",
      },
      body,
      signal: AbortSignal.timeout(20_000),
    });
    return response.status;
  } catch {
    return -1;
  }
};

// Health can be ready before the first request has warmed lazy transforms.
let warmupStatus = -1;
for (let attempt = 0; attempt < 5 && warmupStatus === -1; attempt += 1) {
  warmupStatus = await send();
}
if (warmupStatus === -1) {
  throw new Error("Headroom did not complete the warmup request");
}

const statuses = await Promise.all(Array.from({ length: count }, send));

const counts = Object.fromEntries(
  [...new Set(statuses)]
    .sort((left, right) => left - right)
    .map((status) => [String(status), statuses.filter((value) => value === status).length]),
);
const rateLimited = counts["429"] || 0;
const transportFailures = counts["-1"] || 0;

console.log(
  `HEADROOM_RATE_LIMIT_BURST warmup=${warmupStatus} count=${count} rate_limited=${rateLimited} transport_failures=${transportFailures} statuses=${JSON.stringify(counts)}`,
);

if (rateLimited > 0 || transportFailures > 0) {
  process.exitCode = 1;
}
