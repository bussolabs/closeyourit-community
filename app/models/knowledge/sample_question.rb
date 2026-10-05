# frozen_string_literal: true

module Knowledge
  # Seme di una domanda d'esempio per "Chiedi alla KB" (CYRA-421). Un giro notturno
  # (Knowledge::GenerateSampleQuestionsJob) ne semina qualcuno per ogni progetto a partire dalle sue
  # pagine reali: così sopra il campo compaiono domande su cose che nel progetto esistono davvero,
  # non un placeholder che sparisce appena si scrive.
  #
  # Memorizza il TITOLO e il TIPO della pagina, NON la domanda già resa: il testo si compone a display
  # con i18n (#question), quindi resta nella lingua di chi guarda invece di congelarsi in quella del
  # giro notturno. Ancorata al progetto — chi vede il progetto vede i suoi esempi (nessuno scope nuovo).
  class SampleQuestion < ApplicationRecord
    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :project, class_name: "Projects::Project"
    # La pagina sorgente. Opzionale e nullify a livello DB: se sparisce, il seme resta valido (il
    # titolo è già snapshot qui) fino al prossimo giro notturno che rigenera dai contenuti correnti.
    belongs_to :knowledge_page, class_name: "Knowledge::Page", optional: true

    # Stesso enum di Knowledge::Page: sceglie il template della domanda. prefix per non collidere coi
    # predicati generici (kind_note? ecc.).
    enum :kind, { note: 0, decision: 1, guide: 2 }, prefix: true

    validates :title, presence: true

    scope :for_projects, ->(project_ids) { where(project_id: project_ids) }
    scope :ordered, -> { order(:position, :created_at, :id) }

    # Domanda composta a runtime nella lingua dell'utente: il template dipende dal tipo di pagina, il
    # titolo è quello reale. Costruire le istanze in memoria (senza salvarle) è il modo in cui la
    # pagina fa il fallback quando il giro notturno non ha ancora seminato nulla.
    def question
      I18n.t("member.knowledge.ask.samples.#{kind}", title: title)
    end
  end
end
