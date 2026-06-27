import { Controller } from "@hotwired/stimulus"

// Countdown splash ที่บังหน้าผลจนถึงเวลาเป้าหมาย
// - ปิดอัตโนมัติเมื่อถึงเวลา (time-gate, ไม่จำ — หลังเวลานี้จะไม่โชว์อยู่แล้ว)
// - ปิดด้วยมือเมื่อคลิกครบ N ครั้ง → จำใน localStorage (สำหรับทีมงาน preview ก่อนเวลา)
// inline script ใน view เป็นคน "โชว์ก่อน paint" กัน flash; controller คุม ticking + การปิด
const STORAGE_KEY = "bkk2026-countdown-dismissed"

export default class extends Controller {
  static values = {
    target: String,            // ISO เช่น "2026-06-28T08:00:00+07:00"
    clicksToClose: { type: Number, default: 10 }
  }
  static targets = ["days", "hours", "minutes", "seconds"]

  connect() {
    this.deadline = new Date(this.targetValue).getTime()
    this.clicks = 0

    if (this._dismissed() || Date.now() >= this.deadline) {
      this.close(false)
      return
    }

    this.element.hidden = false
    this._onClick = this.registerClick.bind(this)
    this.element.addEventListener("click", this._onClick)
    this.tick()
    this.timer = setInterval(() => this.tick(), 1000)
  }

  disconnect() {
    clearInterval(this.timer)
    if (this._onClick) this.element.removeEventListener("click", this._onClick)
  }

  tick() {
    const remaining = this.deadline - Date.now()
    if (remaining <= 0) {
      this.close(false)   // ถึงเวลา → เปิดเว็บอัตโนมัติ
      return
    }
    const s = Math.floor(remaining / 1000)
    this._set("days", Math.floor(s / 86400))
    this._set("hours", Math.floor((s % 86400) / 3600))
    this._set("minutes", Math.floor((s % 3600) / 60))
    this._set("seconds", s % 60)
  }

  registerClick() {
    this.clicks += 1
    if (this.clicks >= this.clicksToCloseValue) {
      this.close(true)   // ปิดด้วยมือ → จำไว้
    }
  }

  close(persist) {
    clearInterval(this.timer)
    if (persist) {
      try { localStorage.setItem(STORAGE_KEY, "1") } catch (e) { /* ignore */ }
    }
    this.element.classList.add("is-closing")
    const done = () => { this.element.hidden = true; this.element.classList.remove("is-closing") }
    const reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches
    if (reduce) { done(); return }
    this.element.addEventListener("transitionend", done, { once: true })
    setTimeout(done, 320)   // fallback เผื่อ transitionend ไม่ยิง
  }

  _set(name, value) {
    if (this[`has${name[0].toUpperCase()}${name.slice(1)}Target`]) {
      this[`${name}Target`].textContent = String(value).padStart(2, "0")
    }
  }

  _dismissed() {
    try { return localStorage.getItem(STORAGE_KEY) === "1" } catch (e) { return false }
  }
}
