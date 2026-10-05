# frozen_string_literal: true

# CYRA-78 — l'audit del vault registra ANCHE i tentativi bloccati dal confine ambienti (action
# "denied"), e per leggerli serve sapere da dove arrivavano: `channel` vale "web" o "cli". Nullable
# perché gli eventi già scritti non hanno un canale ricostruibile: si annota da qui in avanti, non si
# inventa il passato.
class AddChannelToSecretsEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :secrets_events, :channel, :string
  end
end
