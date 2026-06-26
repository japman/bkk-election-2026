import { Controller } from "@hotwired/stimulus"

const cdnBase = () => document.querySelector('meta[name="snapshot-cdn"]')?.content || ""

// ตาข่ายนิรภัย (spec §7): ถ้าไม่มี Turbo Stream เข้ามาเกิน staleAfter
// ให้ poll results.json (ผ่าน CDN ใน production) ทุก interval มาอัปเดตตัวเลขแทน
// — Turbo ต่อ WebSocket ใหม่เองเบื้องหลัง เมื่อ stream กลับมา fallback จะหยุดเอง
// หมายเหตุ: ช่วงคะแนนนิ่ง (ไม่มี broadcast จริงๆ) จะ poll ฟรี — ตั้งใจ เพราะถูกผ่าน CDN
// และทำให้ recover อัตโนมัติโดยไม่ต้องเช็คสถานะ socket ตรงๆ
export default class extends Controller {
  static values = {
    url: { type: String, default: "/results.json" },
    interval: { type: Number, default: 10000 },
    staleAfter: { type: Number, default: 15000 }
  }

  connect() {
    this.lastStream = Date.now()
    this.onStream = () => { this.lastStream = Date.now() }
    document.addEventListener("turbo:before-stream-render", this.onStream)
    this.timer = setInterval(() => this.maybePoll(), this.intervalValue)
    this.maybePoll()
  }

  disconnect() {
    document.removeEventListener("turbo:before-stream-render", this.onStream)
    clearInterval(this.timer)
  }

  async maybePoll() {
    if (Date.now() - this.lastStream < this.staleAfterValue) return
    try {
      const res = await fetch(`${cdnBase()}${this.urlValue}`, { cache: "no-store" })
      if (!res.ok) return
      this.patch(await res.json())
    } catch { /* เครือข่ายล้ม — รอบหน้าลองใหม่ */ }
  }

  patch(data) {
    const set = (key, text) => document.querySelectorAll(`[data-live="${key}"]`).forEach(el => {
      if (el.textContent !== text) el.textContent = text
    })
    data.candidates.forEach(c => {
      set(`votes-${c.number}`, c.votes.toLocaleString("th-TH"))
      set(`pct-${c.number}`, `${c.percent}%`)
    })
    set("counted-pct", `${data.counted_percent}%`)
    set("updated-at", `${new Date(data.updated_at).toLocaleTimeString("th-TH", { timeZone: "Asia/Bangkok", hour12: false })} น.`)
    data.zones.forEach(z => {
      const tile = document.querySelector(`[data-zone-code="${z.code}"]`)
      const cand = data.candidates.find(c => c.number === z.leader_number)
      if (tile && cand) tile.style.setProperty("--c", cand.color)
    })
  }
}
