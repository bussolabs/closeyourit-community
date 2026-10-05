# frozen_string_literal: true

require "rails_helper"

# CYRA-824 — chi ha la scheda di un sito aperta la vede cambiare quando il controllo finisce, senza
# ricaricarla a mano. Qui si prova COSA viaggia: un segnale, non una pagina. È il vincolo che rende
# sicuro uno stream condiviso da persone con permessi diversi sullo stesso sito — chi può far
# ripartire un controllo vede due bottoni che l'altro non deve vedere.
RSpec.describe Seo::Broadcast do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:site) { create(:seo_site, project:) }
  let(:stream) { Realtime::Streams.seo_site(site) }

  # In test la cache è null_store (ogni write "riesce") → il throttle non si vedrebbe.
  before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

  it "avvisa chi guarda la scheda di QUEL sito" do
    expect { described_class.state(site) }.to have_broadcasted_to(stream).once
  end

  it "chiede di ricaricare il solo riquadro di stato e risultati, non la pagina intera" do
    expect { described_class.state(site) }
      .to have_broadcasted_to(stream)
      .with(a_string_including('action="refresh_frame"', 'target="seo-site-live"'))
  end

  # IL punto: la scheda mostra i bottoni «Rilancia» e «Modifica» solo a chi ha `seo.manage`, e chi
  # rende il messaggio non sa per chi lo sta rendendo. Un segnale non porta niente da leggere,
  # quindi ognuno se lo ri-chiede con la propria sessione e il filtro lo rifà il controller.
  it "non porta con sé niente da leggere: nessun indirizzo, nessun rilievo" do
    site.update!(base_url: "https://riservato.test")

    expect { described_class.state(site) }
      .to have_broadcasted_to(stream)
      .with(satisfy { |payload| !payload.to_s.include?("riservato.test") })
  end

  it "una raffica non diventa una raffica di segnali" do
    described_class.state(site) # il primo passa subito

    expect { 20.times { described_class.state(site) } }
      .to have_enqueued_job(Realtime::BroadcastRefreshJob).exactly(:once)
  end

  it "il segnale differito resta ristretto allo stesso riquadro" do
    expect { Realtime::BroadcastRefreshJob.perform_now(stream, described_class::LIVE_FRAME) }
      .to have_broadcasted_to(stream).with(a_string_including('action="refresh_frame"'))
  end

  it "due siti, due stream distinti" do
    altro = create(:seo_site, project:)

    expect { described_class.state(site) }
      .not_to have_broadcasted_to(Realtime::Streams.seo_site(altro))
  end

  # Il nome-stream porta l'organizzazione DEL PROGETTO del sito: l'isolamento fra clienti sta nel
  # nome, prima ancora che nel permesso.
  it "il nome dello stream è dell'organizzazione del sito" do
    expect(stream).to include("org:#{organization.id}:")
  end

  # Chi chiama sta concludendo un controllo dentro un `rescue StandardError` che marca il giro come
  # fallito: se un guasto del trasporto risalisse, un controllo RIUSCITO verrebbe riscritto come
  # fallito, con il nome della classe d'errore al posto del motivo. Avvisare chi guarda è un
  # accessorio della lettura, non parte dell'esito.
  it "un guasto del trasporto non risale a chi lo ha chiamato" do
    allow(Realtime::ThrottledRefresh).to receive(:call).and_raise(IOError.new("cable giù"))

    expect { described_class.state(site) }.not_to raise_error
  end

  it "un guasto del trasporto lascia detto cosa è successo" do
    allow(Realtime::ThrottledRefresh).to receive(:call).and_raise(IOError.new("cable giù"))
    expect(Rails.logger).to receive(:warn).with(/Seo::Broadcast.*IOError.*cable giù/)

    described_class.state(site)
  end
end
