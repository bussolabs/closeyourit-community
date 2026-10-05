# frozen_string_literal: true

require "rails_helper"

# CYRA-737 — le pagine dell'area di controllo (errori, log, prestazioni, uptime, falle, siti,
# registrazioni, server, lavori programmati, database) facevano ciascuna la propria versione della
# stessa lista: stesso filtro progetto, stessa ricerca, stessa paginazione, riscritti diciotto volte
# con diciotto sfumature. Sfumature diverse sulla stessa cosa non sono varietà: sono il motivo per
# cui una correzione fatta su una pagina non arriva mai alle altre diciassette.
#
# Qui si guarda il sorgente, non il comportamento: ogni controller dell'area parte dalla stessa base.
# Le prove di comportamento restano i request spec di ciascuna pagina.
RSpec.describe "Ogni pagina dell'area di controllo parte dalla stessa base", type: :model do
  before { Rails.application.eager_load! }

  # Le PAGINE dell'area: i controller che stanno direttamente nella sua cartella. I sotto-controller
  # annidati (Incidents::Updates, LogEntries::Promotions, Analytics::Goals…) non sono pagine-elenco
  # ma azioni annesse a una di queste, e non hanno una lista da condividere.
  def controller_dell_area_monitoring
    Member::BaseController.descendants
                          .select { |klass| klass.name.to_s.split("::") in [ "Member", "Monitoring", String ] }
                          .sort_by(&:name)
  end

  it "sono le diciotto pagine dichiarate dal ticket, non una di meno" do
    expect(controller_dell_area_monitoring.size).to be >= 18
  end

  it "ogni controller dell'area include la base condivisa" do
    scoperti = controller_dell_area_monitoring.reject do |klass|
      klass.include?(Member::Monitoring::Indexable)
    end

    expect(scoperti).to be_empty, <<~MESSAGGIO
      Queste pagine dell'area di controllo non partono dalla base condivisa:

      #{scoperti.map { |klass| "  #{klass.name}" }.join("\n")}

      Aggiungi l'inclusione nel controller:

        include Indexable
    MESSAGGIO
  end

  # Il periodo dell'area arriva dalla base: chi lo includeva a parte ora lo eredita, e nessuno deve
  # ricordarsi di aggiungerlo a mano su una pagina nuova.
  it "il periodo dell'area è disponibile su tutte, senza doverlo includere a parte" do
    senza_periodo = controller_dell_area_monitoring.reject { |klass| klass.include?(TimeRangeable) }

    expect(senza_periodo).to be_empty
  end
end
