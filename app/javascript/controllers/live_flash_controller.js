import { Controller } from "@hotwired/stimulus"

// เมื่อ Turbo Stream สลับ DOM ใหม่ ให้ตัวเลข [data-live] ที่ค่าเปลี่ยนวูบสีเหลือง (.flash)
export default class extends Controller {
  connect() {
    this.snapshot()
    this.observer = new MutationObserver(() => this.flashChanged())
    this.observer.observe(this.element, { childList: true, subtree: true })
  }

  disconnect() {
    this.observer.disconnect()
  }

  snapshot() {
    this.values = {}
    this.element.querySelectorAll("[data-live]").forEach(el => {
      this.values[el.dataset.live] = el.textContent
    })
  }

  flashChanged() {
    this.element.querySelectorAll("[data-live]").forEach(el => {
      const key = el.dataset.live
      if (this.values[key] !== undefined && this.values[key] !== el.textContent) {
        el.classList.remove("flash")
        void el.offsetWidth
        el.classList.add("flash")
      }
    })
    this.snapshot()
  }
}
