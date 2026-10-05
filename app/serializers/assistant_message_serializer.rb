# frozen_string_literal: true

# Un messaggio dell'assistente per i client JSON (canale CLI).
#
# `status` è il campo su cui il client decide se continuare a interrogare: "streaming" = ancora in
# lavorazione, "complete"/"failed" = finito. `tools_used` dice su cosa si fonda la risposta: una
# risposta che dichiara le sue fonti è verificabile, una che non lo fa chiede di essere creduta
# sulla parola.
class AssistantMessageSerializer < ApplicationSerializer
  attributes :id, :content, :error_code, :created_at

  attribute(:role) { |message| message.role }
  attribute(:status) { |message| message.status }
  attribute(:tools_used) { |message| Array(message.tools_used) }
end
