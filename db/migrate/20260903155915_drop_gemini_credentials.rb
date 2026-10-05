# frozen_string_literal: true

class DropGeminiCredentials < ActiveRecord::Migration[8.1]
  # CYRA-765: l'AI la offre il sistema. Le chiavi Gemini collegate dalle organizzazioni non hanno
  # più un consumatore: restare cifrate in tabella sarebbe solo un segreto di terzi da custodire.
  def up
    execute "DELETE FROM integrations_credentials WHERE provider = 'gemini'"
  end

  def down
    # Le chiavi cancellate non si ricostruiscono: ogni organizzazione dovrebbe ricollegarle.
  end
end
