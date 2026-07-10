// k6 load test - three scenarios required by the Observability Lab PRD:
// normal traffic, stress traffic, and failure traffic.
//
// Run a single scenario:
//   k6 run -e SCENARIO=normal  scripts/load-test.js
//   k6 run -e SCENARIO=stress  scripts/load-test.js
//   k6 run -e SCENARIO=failure scripts/load-test.js
//
// Run all three back-to-back (used for the benchmark report):
//   k6 run scripts/load-test.js
//
// Target host defaults to the local Nginx gateway; override with -e BASE_URL=...
import http from "k6/http";
import { check, sleep } from "k6";

const BASE_URL = __ENV.BASE_URL || "http://localhost:8080";
const SCENARIO = __ENV.SCENARIO || "all";

const scenarios = {
  normal: {
    executor: "constant-vus",
    vus: 10,
    duration: "30s",
    exec: "normalTraffic",
  },
  stress: {
    executor: "constant-vus",
    vus: 50,
    duration: "30s",
    exec: "stressTraffic",
    startTime: SCENARIO === "all" ? "35s" : "0s",
  },
  failure: {
    executor: "constant-vus",
    vus: 10,
    duration: "20s",
    exec: "failureTraffic",
    startTime: SCENARIO === "all" ? "70s" : "0s",
  },
};

export const options = {
  scenarios:
    SCENARIO === "all"
      ? scenarios
      : { [SCENARIO]: { ...scenarios[SCENARIO], startTime: "0s" } },
  thresholds: {
    http_req_duration: ["p(95)<2000"],
  },
};

// Normal traffic: the standard success path through the full A->B->C->A chain.
export function normalTraffic() {
  const res = http.get(`${BASE_URL}/service-a/greet-service-b`);
  check(res, { "normal: status is 200": (r) => r.status === 200 });
  sleep(1);
}

// Stress traffic: same path, higher concurrency, no think-time - meant to
// push latency up and reveal degradation in Grafana/Prometheus.
export function stressTraffic() {
  const res = http.get(`${BASE_URL}/service-a/greet-service-b`);
  check(res, { "stress: got a response": (r) => r.status !== 0 });
}

// Failure traffic: hits the lab-only controlled-failure endpoints so the
// error-rate and latency alerts have something real to fire on. Adjust the
// paths below once Person 2's /fail and /slow endpoints are wired up.
export function failureTraffic() {
  const res = http.get(`${BASE_URL}/service-a/fail`, {
    tags: { scenario: "failure" },
  });
  check(res, { "failure: request completed (any status)": (r) => r.status !== 0 });
  sleep(0.5);
}
