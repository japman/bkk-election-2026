require "net/http"

module Drive
  class FolderClient
    class Error < StandardError; end

    LIST_URL     = "https://drive.google.com/embeddedfolderview?id=%s"
    DOWNLOAD_URL = "https://drive.google.com/uc?export=download&id=%s"

    class << self
      # [{ id:, name: }] for a public folder, via the server-rendered embed view.
      def list(folder_id)
        # Net::HTTP returns the body as ASCII-8BIT; the embed view is UTF-8, so
        # re-tag it before scanning or non-ASCII (Thai) filenames stay binary and
        # break downstream String ops (unicode_normalize, File paths).
        html = get(format(LIST_URL, folder_id)).dup.force_encoding("UTF-8")
        html.scan(/id="entry-([A-Za-z0-9_-]{10,60})"[\s\S]{0,1500}?flip-entry-title">([^<]+)</)
            .map { |id, name| { id: id, name: name.strip } }
      end

      def download(file_id)
        get(format(DOWNLOAD_URL, file_id))
      end

      private

      # Drive's uc?export=download returns a 303 to the actual file host, so
      # we must follow redirects (Net::HTTP does not on its own).
      def get(url, redirect_limit = 5)
        raise Error, "too many redirects fetching #{url}" if redirect_limit.negative?
        uri = URI(url)
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                              open_timeout: 10, read_timeout: 30) do |http|
          req = Net::HTTP::Get.new(uri)
          req["User-Agent"] = "Mozilla/5.0"
          http.request(req)
        end
        case res
        when Net::HTTPSuccess
          res.body
        when Net::HTTPRedirection
          location = res["location"] or raise Error, "redirect without Location from #{uri}"
          get(URI.join(uri, location).to_s, redirect_limit - 1)
        else
          raise Error, "HTTP #{res.code} from #{uri}"
        end
      rescue Timeout::Error, SystemCallError, SocketError, OpenSSL::SSL::SSLError, EOFError => e
        raise Error, "#{e.class}: #{e.message}"
      end
    end
  end
end
