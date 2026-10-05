# frozen_string_literal: true

module Knowledge
  # Giro notturno che semina le domande d'esempio di "Chiedi alla KB" (CYRA-421). Per ogni progetto
  # con pagine pubblicate prende le più recenti e ne salva il seme (titolo + tipo): la domanda vera si
  # compone a display via i18n. Rigenerato ogni notte così gli esempi seguono i contenuti reali del
  # momento — pagine nuove entrano, titoli cambiati si aggiornano — invece di restare un testo fisso.
  #
  # Idempotente: sostituisce in blocco i semi di ogni progetto (delete + insert in transazione), quindi
  # un secondo giro non duplica e uno svuotamento del progetto ripulisce i semi rimasti. Nessuna
  # chiamata di rete: sono query + insert. Sulla corsia :batch coi giri notturni lo stesso, perché
  # tocca ogni progetto con pagine pubblicate e la sua durata cresce col parco contenuti.
  class GenerateSampleQuestionsJob < ApplicationJob
    queue_as :batch

    def perform
      relevant_project_ids.each do |project_id|
        project = Projects::Project.find_by(id: project_id)
        refresh(project) if project
      end
    end

    private

    # Progetti da toccare: quelli con almeno una pagina pubblicata diretta (da riseminare) e quelli che
    # hanno ancora semi ma potrebbero aver perso le pagine (da ripulire). Uniti così un progetto svuotato
    # non resta con esempi che non esistono più.
    def relevant_project_ids
      with_pages = Knowledge::Page.live.joins(:page_projects)
                                  .distinct.pluck("connections_page_projects.project_id")
      with_seeds = Knowledge::SampleQuestion.distinct.pluck(:project_id)
      (with_pages + with_seeds).uniq
    end

    def refresh(project)
      pages = Knowledge::Page.live.joins(:page_projects)
                             .where(connections_page_projects: { project_id: project.id })
                             .order(updated_at: :desc, id: :desc)
                             .limit(Knowledge::Constants::SAMPLE_QUESTIONS_PER_PROJECT)
                             .to_a

      Knowledge::SampleQuestion.transaction do
        Knowledge::SampleQuestion.where(project_id: project.id).delete_all
        pages.each_with_index do |page, index|
          Knowledge::SampleQuestion.create!(
            organization_id: project.organization_id, project_id: project.id,
            knowledge_page_id: page.id, title: page.title, kind: page.kind, position: index
          )
        end
      end
    end
  end
end
