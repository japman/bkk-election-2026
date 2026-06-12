import { Controller } from "@hotwired/stimulus"

// สลับธีมสว่าง/มืด — เก็บค่าที่เลือกไว้ใน localStorage
// (ค่าเริ่มต้นตาม prefers-color-scheme ตั้งโดย inline script ใน layout)
export default class extends Controller {
  toggle() {
    const next = document.documentElement.dataset.theme === "dark" ? "light" : "dark"
    document.documentElement.dataset.theme = next
    localStorage.setItem("theme", next)
  }
}
