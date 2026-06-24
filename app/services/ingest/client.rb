require "net/http"
require "json"

module Ingest
  class Client
    class FetchError < StandardError; end

    class << self
      def fetch_results = get("/auto?level=area")
      def fetch_candidates = get("/auto/candidates")

      private

      def get(path)
        uri = URI("#{ENV.fetch('ECT_API_URL')}#{path}")
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                   open_timeout: 5, read_timeout: 10) do |http|
          request = Net::HTTP::Get.new(uri)
          request["Authorization"] = "Bearer #{ENV.fetch('ECT_API_TOKEN')}"
          request["Accept"] = "application/json"
          http.request(request)
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
