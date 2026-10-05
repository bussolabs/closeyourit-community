class RemoveTelegramAlertingChannels < ActiveRecord::Migration[8.1]
  # Consolidamento Telegram: il kind `telegram` (bot BYO org-level) è rimosso a favore del Telegram
  # per-utente (bot ufficiale). Elimina i canali telegram residui (kind = 1) e i loro agganci alle
  # regole, così nessuna riga resta con un enum value inesistente. Le regole continuano a consegnare
  # in-app/email + Telegram personale dei destinatari.
  def up
    execute(<<~SQL.squish)
      DELETE FROM alerting_rule_channels
      WHERE channel_id IN (SELECT id FROM alerting_channels WHERE kind = 1)
    SQL
    execute("DELETE FROM alerting_channels WHERE kind = 1")
  end

  def down
    # I canali telegram cancellati non sono ricostruibili → down non ripristinabile.
  end
end
