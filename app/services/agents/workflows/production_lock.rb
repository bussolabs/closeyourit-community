# frozen_string_literal: true

module Agents
  module Workflows
    # Un rilascio in produzione alla volta, per repository (CYRA-595).
    #
    # Il rilascio in produzione è l'unico passo irreversibile della catena, ed è anche l'unico che
    # oggi non ha niente che lo metta in fila. Il gruppo di concorrenza della CI è per riferimento,
    # quindi due tag dello stesso repository girano in parallelo e finiscono in ordine qualunque: la
    # produzione può restare su una versione più vecchia di quella appena rilasciata.
    #
    # A distanziarli, finora, era una persona che premeva «via libera» un ticket per volta senza
    # sapere di essere l'unico freno. Questo lo rende una regola del sistema.
    #
    # Il predicato sta scritto UNA volta, in due lingue che devono dire la stessa cosa: Ruby per chi
    # decide riga per riga, SQL per la coda che filtra a monte. Due copie che divergono sarebbero due
    # code diverse, e quella rimasta indietro proporrebbe lavoro che l'altra rifiuta — un ticket che
    # gira a vuoto senza che nessuno capisca perché.
    class ProductionLock
      # «Produzione aperta»: avviata e non conclusa, oppure ferma su un blocco di quella fase.
      #
      # Il secondo ramo non è un di più. Quando un rilascio va male, `ReportFailure` e `MarkStale`
      # RIAPRONO la fase — azzerano l'avvio — e solo dopo scrivono il blocco. Senza quel ramo, un
      # rilascio fallito e in attesa di una persona smetterebbe di trattenere la fila, e il rilascio
      # successivo partirebbe proprio mentre quello prima è rotto.
      SQL = <<~SQL.squish.freeze
        agents_workflows.cancelled_at IS NULL
        AND agents_workflows.completed_at IS NULL
        AND (
          agents_workflows.closer_production_started_at IS NOT NULL
          OR (agents_workflows.blocked_at IS NOT NULL AND agents_workflows.blocked_phase = 'closer_production')
        )
      SQL

      # Le lavorazioni che trattengono la fila su questo repository, escluso il workflow dato.
      def self.holders(project:, except: nil)
        scope = Agents::Workflow
                .joins(ticket: :project)
                .where(projects: { id: project.id })
                .where(SQL)
        except ? scope.where.not(agents_workflows: { id: except.id }) : scope
      end

      # Vero quando qualcun altro sta già rilasciando su questo repository.
      def self.locked?(project:, except: nil) = holders(project:, except:).exists?

      # La lavorazione che tiene la fila, per poterlo dire a chi guarda. La più vecchia: è quella che
      # si aspetta davvero, e dire «aspetta quest'altra» senza sapere quale non aiuta nessuno.
      def self.holder(project:, except: nil)
        holders(project:, except:).order(:closer_production_started_at).first
      end

      # Gemello Ruby del predicato SQL, per una lavorazione già caricata. La parità fra i due è
      # verificata da uno spec: qui una divergenza non darebbe un errore, darebbe una coda che
      # propone un lavoro che il claim poi rifiuta.
      def self.open?(workflow)
        return false if workflow.cancelled_at? || workflow.completed_at?

        workflow.closer_production_started_at? ||
          (workflow.blocked_at? && workflow.blocked_phase == "closer_production")
      end
    end
  end
end
