# frozen_string_literal: true

module Support
  module Constants
    BODY_MAX_CHARS = 4_000
    # Details the browser sends with a request; anything else is dropped. CYRA-935
    CLIENT_CONTEXT_KEYS = %w[page page_title window theme timezone].freeze
    CONTEXT_VALUE_MAX_CHARS = 500
    # Where new requests are announced. Unset, the god accounts receive them.
    RECIPIENT_ENV = "SUPPORT_EMAIL"
  end
end
