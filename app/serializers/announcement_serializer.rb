# frozen_string_literal: true

# Banner (annuncio) della status page pubblica di un monitor uptime (canale CLI). level = info /
# maintenance / warning (enum string). starts_at/ends_at delimitano la finestra live; active è il toggle.
class AnnouncementSerializer < ApplicationSerializer
  attributes :id, :monitor_id, :level, :message, :starts_at, :ends_at, :active, :created_at
end
