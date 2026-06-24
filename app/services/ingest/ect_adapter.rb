module Ingest
  # The single binding point to the ECT API payload shape.
  # Policy: any error rejects the whole payload and returns errors for the caller to log.
  class EctAdapter
    Result = Struct.new(:data, :errors) do
      def ok? = errors.empty?
    end

    class << self
      def parse(payload, expected_zone_codes:, candidate_map:)
        unless payload.is_a?(Hash) && payload["success"] == true
          return Result.new({}, [ "payload: success was not true" ])
        end
        areas = payload.dig("data", "areas")
        return Result.new({}, [ "payload: data.areas must be an array" ]) unless areas.is_a?(Array)

        errors = []
        data = {}
        codes = areas.map { |a| area_code(a) }
        missing = expected_zone_codes - codes.compact
        errors << "missing areas: #{missing.join(', ')}" if missing.any?
        unexpected = codes.compact - expected_zone_codes
        errors << "unexpected areas: #{unexpected.join(', ')}" if unexpected.any?
        errors << "area with missing area_number" if codes.any?(&:nil?)
        dupes = codes.compact.tally.select { |_, n| n > 1 }.keys
        errors << "duplicate areas: #{dupes.join(', ')}" if dupes.any?

        areas.each do |a|
          code = area_code(a)
          next if code.nil?
          area_errors = validate_area(a, candidate_map)
          if area_errors.any?
            errors.concat(area_errors.map { |m| "area #{code}: #{m}" })
          else
            data[code] = normalize(a, candidate_map)
          end
        end
        Result.new(data, errors)
      end

      private

      def area_code(a)
        n = a["area_number"]
        n.is_a?(Integer) ? format("%02d", n) : nil
      end

      def validate_area(a, candidate_map)
        errors = []
        results = a["results"]
        return [ "results must be an array" ] unless results.is_a?(Array)

        results.each do |r|
          uuid = r["candidate_id"]
          errors << "unknown candidate_id #{uuid}" unless candidate_map.key?(uuid)
          unless r["votes"].is_a?(Integer) && r["votes"] >= 0
            errors << "votes must be a non-negative integer (#{uuid})"
          end
        end

        meta = a["metadata"]
        return errors + [ "metadata must be a hash" ] unless meta.is_a?(Hash)
        pct = meta["coverage_percentage"]
        errors << "coverage_percentage out of range" unless pct.is_a?(Numeric) && pct.between?(0, 100)
        %w[total_eligible_voters total_votes invalid_votes no_votes].each do |f|
          errors << "#{f} must be a non-negative integer" unless meta[f].is_a?(Integer) && meta[f] >= 0
        end
        errors
      end

      def normalize(a, candidate_map)
        meta = a["metadata"]
        {
          votes: a["results"].to_h { |r| [ candidate_map.fetch(r["candidate_id"]), r["votes"] ] },
          stats: {
            eligible_voters: meta["total_eligible_voters"],
            turnout: meta["total_votes"],
            bad_ballots: meta["invalid_votes"],
            no_vote: meta["no_votes"],
            counted_percent: meta["coverage_percentage"]
          }
        }
      end
    end
  end
end
