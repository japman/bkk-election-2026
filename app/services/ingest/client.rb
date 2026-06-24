require "net/http"
require "json"

module Ingest
  class Client
    class FetchError < StandardError; end

    class << self
      def fetch_results(slug = nil) = get("#{election_base(slug)}/auto?level=area")
      def fetch_candidates(slug = nil, page: 1) = get("#{election_base(slug)}/auto/candidates?page=#{page}")

      private

      # Try each configured API token in randomized order (to spread load across
      # keys and increase the effective rate limit). On any failure (incl. 429),
      # fall through to the next token. Raise only when every token fails.
      def get(path)
        tokens = api_tokens
        raise FetchError, "no ECT API token configured (set ECT_API_TOKENS)" if tokens.empty?

        errors = []
        tokens.shuffle.each do |token|
          return request(path, token)
        rescue FetchError => e
          errors << e.message
        end
        raise FetchError, "all #{tokens.size} ECT token(s) failed: #{errors.join(' | ')}"
      end

      # Comma-separated ECT_API_TOKENS (preferred); falls back to the legacy
      # single ECT_API_TOKEN.
      def api_tokens
        raw = ENV["ECT_API_TOKENS"].presence || ENV["ECT_API_TOKEN"]
        raw.to_s.split(",").map(&:strip).reject(&:empty?)
      end

      # Governor uses ECT_API_URL (full election base). For another election, swap the
      # slug on the same host.
      def election_base(slug)
        base = ENV.fetch("ECT_API_URL")
        return base if slug.nil?
        base.sub(%r{/elections/[^/]+\z}, "/elections/#{slug}")
      end

      def request(url, token)
        uri = URI(url)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                   open_timeout: 5, read_timeout: 10) do |http|
          req = Net::HTTP::Get.new(uri)
          req["Authorization"] = "Bearer #{token}"
          req["Accept"] = "application/json"
          http.request(req)
        end
        raise FetchError, "HTTP #{response.code} from #{uri}" unless response.is_a?(Net::HTTPSuccess)
        JSON.parse(response.body)
      rescue JSON::ParserError => e
        raise FetchError, "invalid JSON from #{uri}: #{e.message}"
      rescue Timeout::Error, SystemCallError, SocketError, OpenSSL::SSL::SSLError, EOFError => e
        raise FetchError, "#{e.class}: #{e.message}"
      end
    end
  end
end
