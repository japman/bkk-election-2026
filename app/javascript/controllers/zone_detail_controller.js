import { Controller } from "@hotwired/stimulus"

// คลิกเขตบนแผนที่ → ดึง top 3 ของเขตจาก results.json มาแสดงใน panel
export default class extends Controller {
  static targets = ["panel", "name", "counted", "rows"]

  async show(event) {
    const code = event.currentTarget.dataset.zoneCode
    this.element.querySelectorAll(".tile.sel").forEach(t => t.classList.remove("sel"))
    event.currentTarget.classList.add("sel")
    try {
      const res = await fetch("/results.json", { cache: "no-store" })
      if (!res.ok) return
      const data = await res.json()
      const zone = data.zones.find(z => z.code === code)
      if (!zone) return
      const byNumber = new Map(data.candidates.map(c => [c.number, c]))
      const sum = zone.top.reduce((s, t) => s + t.votes, 0)
      this.nameTarget.textContent = `เขต${zone.name}`
      this.countedTarget.textContent = `นับแล้ว ${zone.counted_percent}%`
      this.rowsTarget.innerHTML = zone.top.map(t => {
        const c = byNumber.get(t.number)
        const pct = sum === 0 ? 0 : (t.votes * 100 / sum).toFixed(1)
        return `<div class="zd-row">
          <i style="background:${c.color}"></i>
          <span class="zd-name">เบอร์ ${c.number} ${c.name}</span>
          <span class="zd-v num">${t.votes.toLocaleString("th-TH")} (${pct}%)</span>
        </div>`
      }).join("")
      this.panelTarget.classList.add("show")
    } catch { /* เงียบไว้ */ }
  }

  hide() {
    this.panelTarget.classList.remove("show")
    this.element.querySelectorAll(".tile.sel").forEach(t => t.classList.remove("sel"))
  }
}
