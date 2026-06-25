import { Controller } from "@hotwired/stimulus"

const cdnBase = () => document.querySelector('meta[name="snapshot-cdn"]')?.content || ""

// กราฟคะแนนสะสม 3 อันดับแรก — วาดเส้นจาก time-series ที่ server ส่งมาใน results.json (key: trend)
// ไม่สะสมเองฝั่ง client แล้ว → โหลดมาเห็นเส้นเต็มทันที + รอด reload
export default class extends Controller {
  connect() {
    this.poll()
    this.timer = setInterval(() => this.poll(), 30000)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  async poll() {
    try {
      const res = await fetch(`${cdnBase()}/results.json`, { cache: "no-store" })
      if (!res.ok) return
      this.draw(await res.json())
    } catch { /* เครือข่ายล้ม — รอบหน้าลองใหม่ */ }
  }

  draw(data) {
    const W = 600, H = 200, P = 8
    const top3 = (data.candidates || []).slice(0, 3)
    const trend = data.trend || []
    const series = top3.map(c => trend.map(pt => Number(pt.votes?.[String(c.number)] ?? 0)))
    const max = Math.max(1, ...series.flat()) * 1.08
    const n = trend.length

    const path = pts => pts.map((v, i) =>
      `${i === 0 ? "M" : "L"}${(P + i * (W - 2 * P) / Math.max(1, n - 1)).toFixed(1)},` +
      `${(H - P - (v / max) * (H - 2 * P)).toFixed(1)}`).join(" ")

    this.element.innerHTML =
      [40, 80, 120, 160].map(y =>
        `<line x1="0" y1="${y}" x2="${W}" y2="${y}" stroke="rgba(135,142,165,.25)" stroke-width="1"/>`).join("") +
      top3.map((c, idx) => {
        const pts = series[idx]
        if (pts.length === 0) return ""
        const lastX = (P + (n - 1) * (W - 2 * P) / Math.max(1, n - 1)).toFixed(1)
        const lastY = (H - P - (pts[pts.length - 1] / max) * (H - 2 * P)).toFixed(1)
        return `<path d="${path(pts)} L${lastX},${H - P} L${P},${H - P} Z" fill="${c.color}" opacity="0.07"/>` +
               `<path d="${path(pts)}" fill="none" stroke="${c.color}" stroke-width="2.5" stroke-linejoin="round"/>` +
               `<circle cx="${lastX}" cy="${lastY}" r="4" fill="${c.color}"/>`
      }).join("")

    const legend = document.getElementById("chart-legend")
    if (legend) legend.innerHTML = top3.map(c =>
      `<span><i style="background:${c.color}"></i>${c.name}</span>`).join("")
  }
}
