class Admin::ZoneResultsController < ApplicationController
  def edit
    @zone = Election.current.zones.find(params[:id])
    @candidates = Election.current.candidates.order(:number)
    @stat = @zone.zone_stat || @zone.build_zone_stat
    @existing = @zone.vote_results.index_by(&:candidate_id)
  end

  def update
    election = Election.current
    zone = election.zones.find(params[:id])

    # spec §5.3: ทุกการแก้ต้อง confirm
    unless params[:confirm] == "1"
      return redirect_to edit_admin_zone_result_path(zone), alert: "ต้องติ๊กช่องยืนยันก่อนบันทึก"
    end

    votes = params.fetch(:votes, {}).permit!.to_h
      .transform_keys(&:to_i).transform_values(&:to_i)
    known = election.candidates.pluck(:number)
    votes = votes.select { |number, _| known.include?(number) }
    raw_stats = params[:stats]&.permit(:eligible_voters, :turnout, :bad_ballots,
                                       :no_vote, :counted_percent)
    stats = if raw_stats
      {
        eligible_voters: raw_stats[:eligible_voters].to_i,
        turnout:         raw_stats[:turnout].to_i,
        bad_ballots:     raw_stats[:bad_ballots].to_i,
        no_vote:         raw_stats[:no_vote].to_i,
        counted_percent: raw_stats[:counted_percent].to_f
      }
    end

    changed = ResultWriter.new(zone, source: "manual",
                               editor: Current.user.email_address,
                               allow_decrease: true)
                          .apply!(votes, stats: stats)
    if changed
      ResultsBroadcaster.new(election).broadcast_all
      SnapshotPublisher.new(election).publish
    end
    redirect_to admin_root_path, notice: "บันทึกเขต#{zone.name} แล้ว"
  end
end
