import { Controller } from "@hotwired/stimulus"

const cdnBase = () => document.querySelector('meta[name="snapshot-cdn"]')?.content || ""

export default class extends Controller {
  static targets = ["panel", "name", "counted", "rows"]
  static values = { interval: { type: Number, default: 15000 } }

  connect() {
    this.refresh()
    this.timer = setInterval(() => this.refresh(), this.intervalValue)
  }

  disconnect() { clearInterval(this.timer) }

  // poll สด: repaint แผนที่ + ที่นั่ง + header โดยไม่ reload (ผ่าน CloudFront)
  async refresh() {
    try {
      const res = await fetch(`${cdnBase()}/results-council.json`)
      if (!res.ok) return
      this.repaint(await res.json())
    } catch { /* เครือข่ายล้ม — รอบหน้าลองใหม่ */ }
  }

  repaint(data) {
    (data.districts || []).forEach(d => {
      const tile = document.querySelector(`.tile[data-zone-code="${d.code}"]`)
      if (tile && d.winner) tile.style.setProperty("--c", d.winner.color)
    })
    const seats = document.getElementById("council-seats")
    if (seats && data.seats) {
      seats.innerHTML = data.seats.map(s =>
        `<span class="seat-row"><i style="background:${s.color}"></i>` +
        `<span class="party-name">${s.party}</span>` +
        `<b>${s.seats}</b><span class="seat-unit">ที่นั่ง</span></span>`
      ).join("")
    }
    const set = (key, text) => document.querySelectorAll(`[data-live="${key}"]`).forEach(el => {
      if (el.textContent !== text) el.textContent = text
    })
    if (data.counted_percent != null) set("counted-pct", `${data.counted_percent}%`)
    if (data.updated_at) set("updated-at", `${new Date(data.updated_at).toLocaleTimeString("th-TH", { timeZone: "Asia/Bangkok", hour12: false })} น.`)
  }

  // คลิกเขต → ดึงรายละเอียดผู้สมัครในเขตนั้น (เดิม)
  async show(e) {
    const code = e.currentTarget.dataset.zoneCode
    const res = await fetch(`${cdnBase()}/results-council.json`, { cache: "no-store" })
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

  hide() { this.panelTarget.classList.remove("show") }
}
