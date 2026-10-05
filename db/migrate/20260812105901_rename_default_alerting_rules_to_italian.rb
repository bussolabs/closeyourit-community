# frozen_string_literal: true

# CYRA-494 — le regole preconfigurate nascevano con nomi inglesi («Uptime down», «Database
# unreachable») accanto a eventi con nome italiano, e nella stessa riga si leggevano le due lingue.
# Qui si rinominano ai nomi degli eventi, in italiano.
#
# SOLO le regole che portano ancora il nome di default: una regola rinominata da una persona è una
# sua scelta e non si tocca. Le notifiche già emesse non cambiano — salvano il proprio titolo, che
# viene dall'evento e non dal nome della regola.
class RenameDefaultAlertingRulesToItalian < ActiveRecord::Migration[8.1]
  # nome inglese di default → nome italiano. Gli interi dell'enum non servono: il nome basta a
  # riconoscere le righe mai toccate, ed è ciò che rende la migrazione autoconsistente.
  RENAMES = {
    "Uptime down" => "Sito non raggiungibile",
    "Uptime up" => "Sito di nuovo raggiungibile",
    "Server down" => "Macchina non raggiungibile",
    "Server recovered" => "Macchina ripristinata",
    "Systemd service failed" => "Servizio in errore",
    "SMART failing" => "Disco in errore",
    "Database unreachable" => "Database non raggiungibile",
    "Automation stalled" => "Automazione bloccata",
    "Container down" => "Contenitore caduto",
    "Agent host failing" => "Macchina in errore",
    "Agent host stale" => "Macchina silenziosa",
    "Database connection usage" => "Connessioni database alte",
    "Data volume usage" => "Spazio dati quasi pieno",
    "Filesystem inode usage" => "Inode quasi esauriti",
    "Replication disconnected" => "Replica scollegata",
    "Replication recovered" => "Replica ripristinata",
    "Container restart loop" => "Contenitore che si riavvia in continuazione",
    "Container stable" => "Contenitore di nuovo stabile",
    "Containers recovered" => "Contenitori tornati su",
    "Embedding service down" => "Ricerca per significato non raggiungibile"
  }.freeze

  class Rule < ActiveRecord::Base
    self.table_name = "alerting_rules"
  end

  def up
    RENAMES.each { |english, italian| Rule.where(name: english).update_all(name: italian) }
  end

  def down
    RENAMES.each { |english, italian| Rule.where(name: italian).update_all(name: english) }
  end
end
