import { Controller } from "@hotwired/stimulus"

// ซูม/แพนเฉพาะแผนที่ (pinch บนมือถือ + ปุ่ม +/−/รีเซ็ต) — แพนด้วย overflow scroll ของ viewport
// แตะเขตยังทำงานปกติ (action บับเบิลขึ้น zone-detail / council)
export default class extends Controller {
  static targets = ["vp", "canvas"]
  static values = { min: { type: Number, default: 1 }, max: { type: Number, default: 3 } }

  connect() {
    this.scale = 1
    this.d0 = 0
    this.s0 = 1
    this.onStart = (e) => { if (e.touches.length === 2) { e.preventDefault(); this.d0 = this.dist(e); this.s0 = this.scale } }
    this.onMove = (e) => { if (e.touches.length === 2 && this.d0) { e.preventDefault(); this.setScale(this.s0 * this.dist(e) / this.d0) } }
    this.onEnd = () => { this.d0 = 0 }
    this.vpTarget.addEventListener("touchstart", this.onStart, { passive: false })
    this.vpTarget.addEventListener("touchmove", this.onMove, { passive: false })
    this.vpTarget.addEventListener("touchend", this.onEnd)
  }

  disconnect() {
    this.vpTarget.removeEventListener("touchstart", this.onStart)
    this.vpTarget.removeEventListener("touchmove", this.onMove)
    this.vpTarget.removeEventListener("touchend", this.onEnd)
  }

  zoomIn() { this.setScale(this.scale + 0.5) }
  zoomOut() { this.setScale(this.scale - 0.5) }
  reset() { this.setScale(1) }

  dist(e) {
    const a = e.touches[0], b = e.touches[1]
    return Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY)
  }

  setScale(s) {
    this.scale = Math.min(this.maxValue, Math.max(this.minValue, s))
    this.canvasTarget.style.transform = `scale(${this.scale})`
  }
}
