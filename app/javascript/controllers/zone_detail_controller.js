import { Controller } from "@hotwired/stimulus"

const cdnBase = () => document.querySelector('meta[name="snapshot-cdn"]')?.content || ""

// คลิกเขตบนแผนที่ → ดึง top 3 ของเขตจาก results.json มาแสดงใน panel
export default class extends Controller {
  static targets = ["panel", "name", "counted", "stats", "rows"]

  connect() {
    this.currentCode = null
    this.observer = new MutationObserver(() => this.restore())
    this.observer.observe(this.element, { childList: true, subtree: true })
  }

  disconnect() {
    this.observer.disconnect()
  }

  restore() {
    if (!this.currentCode) return
    const tile = this.element.querySelector(`[data-zone-code="${this.currentCode}"]`)
    if (tile && !tile.classList.contains("sel")) tile.classList.add("sel")
  }

  show(event) {
    const code = event.currentTarget.dataset.zoneCode
    this.element.querySelectorAll(".tile.sel").forEach(t => t.classList.remove("sel"))
    event.currentTarget.classList.add("sel")
    this.currentCode = code
    this.render(code)
  }

  async render(code) {
    try {
      const res = await fetch(`${cdnBase()}/results.json`, { cache: "no-store" })
      if (!res.ok) return
      const data = await res.json()
      const zone = data.zones.find(z => z.code === code)
      if (!zone) return
      const byNumber = new Map(data.candidates.map(c => [c.number, c]))
      const sum = zone.results.reduce((s, r) => s + r.votes, 0)

      this.nameTarget.textContent = `เขต${zone.name}`
      this.countedTarget.textContent = `นับแล้ว ${zone.counted_percent}%`

      const s = zone.stats || {}
      const nf = (n) => (n || 0).toLocaleString("th-TH")
      const turnoutPct = s.eligible_voters ? (s.turnout * 100 / s.eligible_voters).toFixed(1) : "0.0"
      this.statsTarget.innerHTML =
        `ผู้มีสิทธิ์ ${nf(s.eligible_voters)} • มาใช้สิทธิ์ ${nf(s.turnout)} (${turnoutPct}%) • บัตรเสีย ${nf(s.bad_ballots)} • ไม่ประสงค์ ${nf(s.no_vote)}`

      this.rowsTarget.innerHTML = zone.results.map(t => {
        const c = byNumber.get(t.number)
        if (!c) return ""
        const pct = sum === 0 ? 0 : (t.votes * 100 / sum).toFixed(1)
        return `<div class="zd-row">
        ${c.photo_url ? `<img class="zd-photo" src="${c.photo_url}" alt="" loading="lazy">` : `<i style="background:${c.color}"></i>`}
        <span class="zd-name">เบอร์ ${c.number} ${c.name}${c.party_logo_url ? ` <img class="party-logo" src="${c.party_logo_url}" alt="">` : ""}</span>
        <span class="zd-v num">${t.votes.toLocaleString("th-TH")} (${pct}%)</span>
      </div>`
      }).join("")
      this.panelTarget.classList.add("show")
    } catch { /* เงียบไว้ */ }
  }

  hide() {
    this.currentCode = null
    this.panelTarget.classList.remove("show")
    this.element.querySelectorAll(".tile.sel").forEach(t => t.classList.remove("sel"))
  }
}
