# frozen_string_literal: true

# Wikitech (CYRA-1127): external tech knowledge of an organization (tools, libraries, open-source
# repos seen around), never knowledge about its own projects — that belongs to the knowledge base.
module Wikitech
  def self.table_name_prefix = "wikitech_"
end
