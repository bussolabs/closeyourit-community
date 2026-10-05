# frozen_string_literal: true

# CYRA-747 — Guardia contro le letture a raffica (una query al database per ogni riga mostrata).
#
# COSA FA: durante una richiesta sotto prova, ogni record che arriva da una LISTA — una query che ne
# ha restituiti almeno due — viene marcato `strict_loading`. Da quel momento leggere su di lui
# un'associazione che nessuno ha precaricato SOLLEVA `ActiveRecord::StrictLoadingViolationError`
# invece di aggiungere in silenzio una query per riga. Il messaggio nomina il modello e
# l'associazione, quindi la prova rossa dice già dove va messo il preload.
#
# PERCHÉ NON BASTA PROSOPITE (spec/support/prosopite.rb): Prosopite guarda le query RIPETUTE, quindi
# vede la raffica solo quando le righe che la innescano sono abbastanza. Una lista in cui una sola
# riga tira l'associazione fa UNA query in più: nella prova è una query sola e Prosopite tace, in
# produzione — dove quelle righe sono migliaia — è la pagina che non si apre più. Qui la violazione
# è la lettura pigra in sé, non la sua ripetizione. Le due guardie restano complementari: Prosopite
# copre anche le query ripetute che non passano da un'associazione.
#
# PERCHÉ NON `config.active_record.strict_loading_by_default`: marcherebbe ogni record, compresi
# quelli letti uno alla volta (`find`, `find_by`, l'account della sessione), dove una lettura pigra
# è una query e basta. Misurato su questo repository: 56 esempi rossi su 57 in un solo file
# dell'area member, senza un N+1 da nessuna parte. Il confine "almeno due record dalla stessa query"
# è ciò che rende la guardia sostenibile.
#
# SCOPE: solo i **request spec**, come Prosopite. Fuori da una richiesta la stessa lettura non è
# una raffica da correggere: un job che carica una lista per distruggerla in cascata DEVE caricare
# le associazioni dipendenti (`destroy_all`), e il costo non lo paga nessuno davanti a una pagina.
# Le action restano coperte perché sono i request spec a esercitarle.
#
# IN PRODUZIONE NON CAMBIA NIENTE: questo file vive sotto `spec/`, lo carica soltanto rspec.
module StrictLoadingLists
  class << self
    # Accesa dentro un request spec, spenta fuori.
    attr_accessor :armed
    # Sospesa per il tratto di codice che ha un motivo scritto (mai a tappeto).
    attr_accessor :suspended

    def active? = armed && !suspended
  end
  self.armed = false
  self.suspended = false

  def exec_queries(&)
    records = super
    return records unless StrictLoadingLists.active?
    # `strict_loading_value` non nil = la relation ha già deciso da sé, in un senso o nell'altro:
    # quella decisione è del codice di produzione e vince su questa guardia.
    return records unless strict_loading_value.nil?
    return records unless records.size > 1

    records.each { |record| record.strict_loading!(true, mode: :all) }
    records
  end
end

ActiveRecord::Relation.prepend(StrictLoadingLists)

module StrictLoadingHelpers
  # Eccezione puntuale e motivata (mai a tappeto): un tratto in cui la lettura pigra su una lista è
  # deliberata — per esempio il setup che costruisce dati e poi li rilegge per verificarli, dove le
  # query non sono quelle che l'utente paga aprendo la pagina. Sempre con commento sul perché.
  def allow_lazy_loading
    was = StrictLoadingLists.suspended
    StrictLoadingLists.suspended = true
    yield
  ensure
    StrictLoadingLists.suspended = was
  end
end

RSpec.configure do |config|
  config.include StrictLoadingHelpers

  config.before(:each, type: :request) { StrictLoadingLists.armed = true }
  config.after(:each, type: :request) { StrictLoadingLists.armed = false }
end
