import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["panel", "name", "counted", "rows"]

  async show(e) {
    const code = e.currentTarget.dataset.zoneCode
    const res = await fetch("/results-council.json", { cache: "no-store" })
    if (!res.ok) return
    const data = await res.json()
    const d = (data.districts || []).find(x => x.code === code)
    if (!d) return
    const sum = d.results.reduce((s, r) => s + r.votes, 0)
    this.nameTarget.textContent = `เขต${d.name}`
    this.countedTarget.textContent = `นับแล้ว ${d.counted_percent}%`
    this.rowsTarget.innerHTML = d.results.map((r, i) => {
      const pct = sum === 0 ? 0 : (r.votes * 100 / sum).toFixed(1)
      return `<div class="zd-row ${i === 0 ? "winner" : ""}">
        ${r.photo_url ? `<img class="zd-photo" src="${r.photo_url}" alt="" loading="lazy">` : `<i style="background:${r.color}"></i>`}
        <span class="zd-name">เบอร์ ${r.number} ${r.name} <small>${r.party || ""}</small></span>
        <span class="zd-v num">${r.votes.toLocaleString("th-TH")} (${pct}%)</span>
      </div>`
    }).join("")
    this.panelTarget.classList.add("show")
  }

  hide() {
    this.panelTarget.classList.remove("show")
  }
}
