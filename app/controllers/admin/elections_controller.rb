class Admin::ElectionsController < ApplicationController
  # โหมด manual: ingest หยุดเขียนทับ จนกว่าจะสลับกลับ (spec §5.3)
  def toggle_mode
    election = Election.current
    election.update!(data_mode: election.api? ? "manual" : "api")
    redirect_to admin_root_path, notice: "สลับโหมดข้อมูลเป็น #{election.data_mode} แล้ว"
  end

  def toggle_streaming
    election = Election.current
    election.update!(live_streaming: !election.live_streaming?)
    redirect_to admin_root_path,
      notice: "Live WS: #{election.live_streaming? ? 'เปิด (push สด)' : 'ปิด (โหมด peak — ทุกคน poll CDN)'}"
  end
end
