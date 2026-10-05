# frozen_string_literal: true

require "rails_helper"

# CYRA-730 — l'emissione della chiave con cui una macchina si presenta all'ingresso dei dati. Il
# segreto in chiaro esiste una volta sola, nella risposta: sul database resta solo la sua impronta.
# Se qui si salvasse il segreto, chi legge la tabella potrebbe parlare al posto delle macchine.
RSpec.describe Servers::HostTokens::Issue, type: :service do
  let(:host) { create(:server_host) }

  it "emette la chiave e la lega alla macchina" do
    result = described_class.call(host: host)

    expect(result).to be_ok
    expect(result.value[:token].host).to eq(host)
    expect(host.host_tokens.count).to eq(1)
  end

  it "il segreto in chiaro torna al chiamante ma non viene salvato" do
    segreto = described_class.call(host: host).value[:secret]

    expect(segreto).to be_present
    expect(Servers::HostToken.where(token_digest: segreto)).to be_empty
  end

  it "sul database resta solo l'impronta del segreto" do
    esito = described_class.call(host: host).value

    expect(esito[:token].token_digest).to eq(Digest::SHA256.hexdigest(esito[:secret]))
  end

  # Il prefisso è quel che si mostra nella pagina per riconoscere una chiave senza rivelarla.
  it "conserva un prefisso riconoscibile del segreto" do
    esito = described_class.call(host: host).value

    expect(esito[:secret]).to start_with("cyi_h_")
    expect(esito[:token].token_prefix).to eq(esito[:secret].first(14))
  end

  it "due emissioni non danno mai lo stesso segreto" do
    primo = described_class.call(host: host).value[:secret]
    host.host_tokens.update_all(revoked_at: Time.current)
    secondo = described_class.call(host: host).value[:secret]

    expect(primo).not_to eq(secondo)
  end

  # Una macchina ha una sola chiave viva: il database lo impone con un vincolo, e il servizio deve
  # rispondere con un errore leggibile invece di lasciar salire l'eccezione fino a una pagina rotta.
  it "chiave già viva sulla stessa macchina → errore dichiarato, non un'eccezione" do
    described_class.call(host: host)

    result = described_class.call(host: host)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-SERVER-005")
  end

  it "la chiave revocata non impedisce di emetterne una nuova" do
    described_class.call(host: host)
    host.host_tokens.update_all(revoked_at: Time.current)

    expect(described_class.call(host: host)).to be_ok
  end

  it "record non valido → errore dichiarato con lo stesso codice" do
    allow_any_instance_of(Servers::HostToken).to receive(:save!)
      .and_raise(ActiveRecord::RecordInvalid.new(Servers::HostToken.new))

    result = described_class.call(host: host)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-SERVER-005")
  end
end
