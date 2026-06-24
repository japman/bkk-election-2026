require "net/http"

module Drive
  class FolderClient
    class Error < StandardError; end

    LIST_URL     = "https://drive.google.com/embeddedfolderview?id=%s"
    DOWNLOAD_URL = "https://drive.google.com/uc?export=download&id=%s"

    class << self
      # [{ id:, name: }] for a public folder, via the server-rendered embed view.
      def list(folder_id)
        html = get(format(LIST_URL, folder_id))
        html.scan(/id="entry-([A-Za-z0-9_-]{10,60})"[\s\S]{0,1500}?flip-entry-title">([^<]+)</)
            .map { |id, name| { id: id, name: name.strip } }
      end

      def download(file_id)
        get(format(DOWNLOAD_URL, file_id))
      end

      private

      def get(url)
        uri = URI(url)
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                              open_timeout: 10, read_timeout: 30) do |http|
          req = Net::HTTP::Get.new(uri)
          req["User-Agent"] = "Mozilla/5.0"
          http.request(req)
        end
        raise Error, "HTTP #{res.code} from #{uri}" unless res.is_a?(Net::HTTPSuccess)
        res.body
      rescue Timeout::Error, SystemCallError, SocketError, OpenSSL::SSL::SSLError, EOFError => e
        raise Error, "#{e.class}: #{e.message}"
      end
    end
  end
end
