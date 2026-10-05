# frozen_string_literal: true

module Chat
  module Notifications
    # Snapshot umano (title/body/url) di una notifica di chat, congelato sulla notifica → resta
    # leggibile anche se il messaggio viene poi eliminato. Twin di Ticketing::Notifications::Content.
    Content = Data.define(:title, :body, :url)
  end
end
