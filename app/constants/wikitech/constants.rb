# frozen_string_literal: true

module Wikitech
  module Constants
    # A note is the text extracted from one piece of content (a video transcript plus the project
    # pages read for it). Large enough for that, small enough for one AI extraction call.
    NOTE_BODY_MAX_CHARS = 20_000
    SOURCE_LABEL_MAX_CHARS = 120
    NOTE_LINKS_MAX = 50

    # Card fields written by the AI: one short paragraph, a handful of facts, a few categories.
    # "What it is for" fits one row of the cards list.
    SUMMARY_MAX_CHARS = 80
    FACT_MAX_CHARS = 280
    FACTS_MAX = 12
    CATEGORIES_MAX = 6
    QUOTE_MAX_CHARS = 280

    # One note can present ten projects with their facts: the default 2048 tokens cut it short.
    EXTRACT_MAX_OUTPUT_TOKENS = 8192

    # Element list pages: 12 rows (global data-tables rule).
    PER_PAGE = 12
  end
end
