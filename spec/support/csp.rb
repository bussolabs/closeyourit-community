# frozen_string_literal: true

# CYRA-715 — leggere la Content Security Policy di una risposta. La policy viaggia su due header
# diversi a seconda del canale (l'area autenticata BLOCCA, il sito pubblico raccoglie e basta): una
# prova che ne guardasse uno solo diventerebbe verde per il motivo sbagliato appena il canale cambia
# modo, perché `nil` non contiene mai la direttiva che si sta cercando di escludere.
module CspHelpers
  # La policy attiva sulla risposta, qualunque sia il modo. Pretende che ci sia: una risposta senza
  # policy è già di per sé il guasto da segnalare.
  def csp_of(response)
    policy = response.headers["Content-Security-Policy"] || response.headers["Content-Security-Policy-Report-Only"]
    expect(policy).to be_present, "nessuna Content Security Policy sulla risposta"
    policy
  end

  # Una direttiva sola, es. `directive_of(csp, "script-src")` → "script-src 'self' 'nonce-…'".
  # Stringa vuota se la direttiva non c'è (che per frame-ancestors è proprio il caso da provare).
  def directive_of(policy, name)
    policy.to_s.split(";").map(&:strip).find { |part| part.start_with?("#{name} ") }.to_s
  end

  # Il codice che autorizza i nostri script inline, estratto da script-src.
  def csp_nonce_in(policy)
    directive_of(policy, "script-src")[/'nonce-([^']+)'/, 1]
  end
end

RSpec.configure do |config|
  config.include CspHelpers, type: :request
end
