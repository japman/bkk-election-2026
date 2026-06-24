import { Controller } from "@hotwired/stimulus"

// Council map controller — zone tile click handler (zone detail wired in Task 11)
export default class extends Controller {
  connect() {
    this.currentCode = null
  }

  show(event) {
    const code = event.currentTarget.dataset.zoneCode
    this.currentCode = code
    // Zone detail panel rendering added in Task 11
  }
}
