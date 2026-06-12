// จำลอง client ฝั่ง fallback: ~800 req/s ใส่ results.json (ผ่าน CloudFront)
// รัน: k6 run -e POLL_URL=https://staging-cdn.example/results.json loadtest/poll.js
import http from "k6/http";
import { check } from "k6";

export const options = {
  scenarios: {
    pollers: {
      executor: "constant-arrival-rate",
      rate: 800,
      timeUnit: "1s",
      duration: "10m",
      preAllocatedVUs: 1000,
      maxVUs: 2000
    }
  },
  thresholds: {
    http_req_duration: ["p(95)<1000"],
    http_req_failed: ["rate<0.01"]
  }
};

export default function () {
  const res = http.get(__ENV.POLL_URL);
  check(res, { "status 200": r => r.status === 200 });
}
