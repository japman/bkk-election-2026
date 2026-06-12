module Ingest
  # จุดเดียวที่ผูกกับ format ของ API กกต./พาร์ทเนอร์ (spec §9)
  # ถ้า spec จริงคลาดเคลื่อน แก้ mapping ที่ไฟล์นี้ไฟล์เดียว
  # นโยบาย: payload มี error ใดๆ = reject ทั้งก้อน + คืน errors ให้ caller log (spec §7)
  class EctAdapter
    Result = Struct.new(:data, :errors) do
      def ok? = errors.empty?
    end

    class << self
      def parse(raw, expected_zone_codes:, known_numbers:)
        json = JSON.parse(raw)
        zones = json["zones"]
        return Result.new({}, [ "payload: zones must be an array" ]) unless zones.is_a?(Array)

        errors = []
        data = {}
        missing = expected_zone_codes - zones.map { |z| z["code"].to_s }
        errors << "missing zones: #{missing.join(', ')}" if missing.any?

        codes = zones.map { |z| z["code"].to_s }
        unexpected = codes.reject(&:empty?) - expected_zone_codes
        errors << "unexpected zones: #{unexpected.join(', ')}" if unexpected.any?
        errors << "zone with missing code" if codes.any?(&:empty?)
        dupes = codes.tally.select { |_, n| n > 1 }.keys
        errors << "duplicate zone codes: #{dupes.join(', ')}" if dupes.any?

        zones.each do |z|
          zone_errors = validate_zone(z, known_numbers)
          if zone_errors.any?
            errors.concat(zone_errors.map { |msg| "zone #{z['code']}: #{msg}" })
          else
            data[z["code"].to_s] = normalize(z)
          end
        end
        Result.new(data, errors)
      rescue JSON::ParserError => e
        Result.new({}, [ "invalid JSON: #{e.message}" ])
      end

      private

      def validate_zone(z, known_numbers)
        errors = []
        results = z["results"]
        return [ "results must be an array" ] unless results.is_a?(Array)

        results.each do |r|
          errors << "unknown candidate ##{r['number']}" unless known_numbers.include?(r["number"])
          unless r["votes"].is_a?(Integer) && r["votes"] >= 0
            errors << "votes must be a non-negative integer (##{r['number']})"
          end
        end
        pct = z["counted_percent"]
        errors << "counted_percent out of range" unless pct.is_a?(Numeric) && pct.between?(0, 100)
        %w[eligible turnout bad no_vote].each do |field|
          errors << "#{field} must be a non-negative integer" unless z[field].is_a?(Integer) && z[field] >= 0
        end
        errors
      end

      def normalize(z)
        {
          votes: z["results"].to_h { |r| [ r["number"], r["votes"] ] },
          stats: {
            eligible_voters: z["eligible"], turnout: z["turnout"],
            bad_ballots: z["bad"], no_vote: z["no_vote"],
            counted_percent: z["counted_percent"]
          }
        }
      end
    end
  end
end
