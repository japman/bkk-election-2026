require "net/http"

module Ingest
  # แยก HTTP ออกมาให้ stub ง่ายใน test — retry/backoff เป็นหน้าที่ของ job
  class Client
    class FetchError < StandardError; end

    def self.fetch
      uri = URI(ENV.fetch("ECT_API_URL"))
      response = Net::HTTP.get_response(uri)
      raise FetchError, "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      response.body
    end
  end
end
