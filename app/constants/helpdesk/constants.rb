# frozen_string_literal: true

module Helpdesk
  module Constants
    BODY_MAX_CHARS = 4_000
    SUMMARY_MAX_CHARS = 140
    EMAIL_MAX_CHARS = 254
    PAGE_URL_MAX_CHARS = 2_000
    SESSION_ID_MAX_CHARS = 64
    # A field people never see: only a bot fills it. CYRA-940
    HONEYPOT_FIELD = "website"
    # How long a visitor's address is kept: long enough to answer, not forever.
    EMAIL_RETENTION = 180.days
    # Answers written to one visitor: a conversation, not a mailing. CYRA-943
    REPLIES_PER_REQUEST_MAX = 20
  end
end
