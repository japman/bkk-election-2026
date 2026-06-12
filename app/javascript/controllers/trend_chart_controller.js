import { Controller } from "@hotwired/stimulus"

// กราฟคะแนนสะสม 3 อันดับแรก — ดึงจุดใหม่จาก results.json ทุก 30 วิ
// history อยู่ระดับ module เพื่อรอดตอน Turbo Stream replace #overview-stats
// (Stimulus controller โดน disconnect/reconnect ทุก broadcast)
const history = new Map() // number -> [votes...]

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
      const res = await fetch("/results.json", { cache: "no-store" })
      if (!res.ok) return
      const data = await res.json()
      const top3 = data.candidates.slice(0, 3)
      top3.forEach(c => {
        const pts = history.get(c.number) || []
        if (pts[pts.length - 1] !== c.votes) pts.push(c.votes)
        if (pts.length > 12) pts.shift()
        history.set(c.number, pts)
      })
      this.draw(top3)
    } catch { /* เครือข่ายล้ม — รอบหน้าลองใหม่ */ }
  }

  draw(top3) {
    const W = 600, H = 200, P = 8
    const max = Math.max(1, ...top3.flatMap(c => history.get(c.number) || [])) * 1.08
    const line = pts => pts.map((v, i) =>
      `${i === 0 ? "M" : "L"}${(P + i * (W - 2 * P) / Math.max(1, pts.length - 1)).toFixed(1)},` +
      `${(H - P - (v / max) * (H - 2 * P)).toFixed(1)}`).join(" ")

    this.element.innerHTML =
      [40, 80, 120, 160].map(y =>
        `<line x1="0" y1="${y}" x2="${W}" y2="${y}" stroke="rgba(135,142,165,.25)" stroke-width="1"/>`).join("") +
      top3.map(c => {
        const pts = history.get(c.number) || []
        if (pts.length === 0) return ""
        const x = pts.length === 1 ? P : P + (pts.length - 1) * (W - 2 * P) / (pts.length - 1)
        const y = H - P - (pts[pts.length - 1] / max) * (H - 2 * P)
        return `<path d="${line(pts)} L${x.toFixed(1)},${H - P} L${P},${H - P} Z" fill="${c.color}" opacity="0.07"/>` +
               `<path d="${line(pts)}" fill="none" stroke="${c.color}" stroke-width="2.5" stroke-linejoin="round"/>` +
               `<circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="4" fill="${c.color}"/>`
      }).join("")

    const legend = document.getElementById("chart-legend")
    if (legend) legend.innerHTML = top3.map(c =>
      `<span><i style="background:${c.color}"></i>${c.name}</span>`).join("")
  }
}
