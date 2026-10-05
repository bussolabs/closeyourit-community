# frozen_string_literal: true

require "rails_helper"

# CYRA-722 — la sospensione vale su ogni canale, e il modo di dimenticarsene è sempre lo stesso:
# scrivere un'autenticazione nuova che pinna l'organizzazione e non chiede se è ancora attiva. È
# successo mentre si scriveva questa correzione — l'ingest dell'API v1 ha un'autenticazione propria,
# che unifica bearer e DSN, e non passa per le concern: senza questa guardia sarebbe rimasto l'unico
# canale aperto a un'organizzazione fermata.
#
# Qui si controlla il sorgente, non il comportamento: ogni punto che assegna Current.organization
# deve chiedere della sospensione subito dopo. È una rete, non una prova — le prove vere stanno in
# spec/requests/suspended_organization_channels_spec.rb e spec/requests/member/.
RSpec.describe "Ogni canale controlla la sospensione dell'organizzazione", type: :model do
  # Il canale web ha il suo guard (require_active_organization, montato come before_action) perché
  # deve rendere una PAGINA, non un envelope JSON: qui non c'entra.
  ESENTI = %w[app/controllers/concerns/organization_context.rb].freeze

  # Entro quante righe dal pin deve comparire la domanda. Largo abbastanza da lasciar respirare il
  # codice (qualche assegnazione di contesto in mezzo), stretto abbastanza da non premiare un
  # controllo che sta in fondo al metodo, dopo che il lavoro è già stato fatto.
  RIGHE_DI_GRAZIA = 6

  def sorgenti
    Dir[Rails.root.join("app/controllers/**/*.rb")].map { |path| Pathname(path).relative_path_from(Rails.root).to_s }
  end

  it "chi pinna l'organizzazione chiede se è sospesa" do
    mancanti = sorgenti.reject { |path| ESENTI.include?(path) }.flat_map do |path|
      righe = Rails.root.join(path).readlines
      righe.each_with_index.filter_map do |riga, i|
        next unless riga.include?("Current.organization =")

        finestra = righe[i, RIGHE_DI_GRAZIA + 1].join
        "#{path}:#{i + 1}" unless finestra.include?("reject_suspended_organization!")
      end
    end

    expect(mancanti).to be_empty,
                        "Pinnano Current.organization senza controllare la sospensione:\n#{mancanti.join("\n")}"
  end
end
