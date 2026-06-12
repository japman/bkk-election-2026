module ApplicationCable
  # Allow anonymous connections — the public dashboard subscribes to signed
  # Turbo::StreamsChannel streams without a session cookie.
  # Admin-only channels can enforce auth at the channel level instead.
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      set_current_user
      # Do NOT call reject_unauthorized_connection: anonymous visitors must
      # be able to receive live result updates via signed stream "results".
    end

    private
      def set_current_user
        if session = Session.find_by(id: cookies.signed[:session_id])
          self.current_user = session.user
        end
      end
  end
end
