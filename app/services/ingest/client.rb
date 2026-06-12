require "net/http"

module Ingest
  # แยก HTTP ออกมาให้ stub ง่ายใน test — retry/backoff เป็นหน้าที่ของ job
  class Client
    class FetchError < StandardError; end

    def self.fetch
      uri = URI(ENV.fetch("ECT_API_URL"))
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                 open_timeout: 5, read_timeout: 10) do |http|
        http.get(uri.request_uri)
      end
      raise FetchError, "HTTP #{response.code} from #{uri.host}" unless response.is_a?(Net::HTTPSuccess)

      response.body
    rescue Timeout::Error, SystemCallError, SocketError, OpenSSL::SSL::SSLError, EOFError => e
      raise FetchError, "#{e.class}: #{e.message}"
    end
  end
end
