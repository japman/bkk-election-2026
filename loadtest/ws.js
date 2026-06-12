// 6,000 WebSocket subscribers ค้าง connection 10 นาที (spec §8.3)
// วิธีหา SIGNED_STREAM: เปิดหน้าเว็บ staging → view source →
//   <turbo-cable-stream-source signed-stream-name="..."> เอาค่านั้นมาใส่
// รัน: k6 run -e WS_URL=wss://staging.example/cable -e SIGNED_STREAM=xxx loadtest/ws.js
import ws from "k6/ws";
import { check } from "k6";

export const options = {
  scenarios: {
    subscribers: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "2m", target: 6000 },
        { duration: "8m", target: 6000 }
      ]
    }
  }
};

export default function () {
  const res = ws.connect(__ENV.WS_URL, {}, socket => {
    socket.on("open", () => {
      socket.send(JSON.stringify({
        command: "subscribe",
        identifier: JSON.stringify({
          channel: "Turbo::StreamsChannel",
          signed_stream_name: __ENV.SIGNED_STREAM
        })
      }));
    });
    socket.setTimeout(() => socket.close(), 9.5 * 60 * 1000);
  });
  check(res, { "ws status 101": r => r && r.status === 101 });
}
