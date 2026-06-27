namespace :election do
  # รีเซ็ตข้อมูลนับคะแนนให้กลับเป็น 0% สะอาด (โหมด manual) เหมือนเช้าวันเลือกตั้งก่อนเริ่มนับ
  # เก็บ scaffold ไว้ครบ: Election / Zone(50) / Candidate
  # ลบเฉพาะ tally: VoteResult, ZoneStat, TrendPoint (+ ResultRevision ที่ผูกอยู่)
  # Dry-run เป็น default — ต้องสั่ง CONFIRM=yes ถึงจะลบจริง
  #   ตรวจ:  kamal app exec --reuse "bin/rake election:clear_for_real_day"
  #   ลบจริง: kamal app exec --reuse -e CONFIRM=yes "bin/rake election:clear_for_real_day"
  desc "Reset tally to a clean 0% (manual mode) for the real election day. Dry-run unless CONFIRM=yes."
  task clear_for_real_day: :environment do
    elections = [ Election.governor, Election.council ].compact
    abort "No elections found — aborting." if elections.empty?

    report = lambda do |label|
      puts "=== #{label} ==="
      elections.each do |e|
        votes = VoteResult.joins(:zone).where(zones: { election_id: e.id }).count
        stats = ZoneStat.where(zone: e.zones).count
        puts "[#{e.kind}] mode=#{e.data_mode} vote_results=#{votes} " \
             "zone_stats=#{stats} trend_points=#{e.trend_points.count} " \
             "counted=#{e.counted_percent}% total_votes=#{e.total_votes}"
      end
      puts "result_revisions(total)=#{ResultRevision.count}"
    end

    report.call("BEFORE")

    unless ENV["CONFIRM"] == "yes"
      puts "\nDRY-RUN — ไม่มีการเปลี่ยนแปลง. รันซ้ำด้วย CONFIRM=yes เพื่อลบจริง."
      next
    end

    puts "\nCONFIRM=yes — กำลังลบ + ตั้ง manual ..."
    ActiveRecord::Base.transaction do
      elections.each do |e|
        e.update!(data_mode: "manual")
        # destroy_all เพื่อให้ dependent: :destroy ลบ ResultRevision (polymorphic) ตามไปด้วย
        VoteResult.joins(:zone).where(zones: { election_id: e.id }).destroy_all
        ZoneStat.where(zone: e.zones).destroy_all
        e.trend_points.delete_all
      end
    end

    puts "Republishing snapshots + broadcasting ..."
    elections.each do |e|
      SnapshotPublisher.new(e).publish
      # broadcaster targets หน้า governor เท่านั้น (council ใช้ snapshot polling) — ตามพฤติกรรม IngestPollJob
      ResultsBroadcaster.new(e).broadcast_all if e.kind == "governor"
    end

    elections.each(&:reload)
    report.call("AFTER")
    puts "\nDone — ข้อมูลถูกรีเซ็ตเป็น 0% (manual). poll 30 วิจะไม่เติมกลับเพราะอยู่โหมด manual."
  end
end
