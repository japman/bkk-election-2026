# push อัปเดตทุก region ของหน้า dashboard ผ่าน stream "results"
# target id ต้องตรงกับ root element ของแต่ละ partial ใน app/views/dashboard/
class ResultsBroadcaster
  REGIONS = [
    ["header-status",  "dashboard/header_status"],
    ["leaderboard",    "dashboard/leaderboard"],
    ["zone-map",       "dashboard/map"],
    ["overview-stats", "dashboard/stats"]
  ].freeze

  def initialize(election)
    @election = election
  end

  def broadcast_all
    REGIONS.each do |target, partial|
      Turbo::StreamsChannel.broadcast_replace_to(
        "results", target: target, partial: partial, locals: { election: @election }
      )
    end
  end
end
