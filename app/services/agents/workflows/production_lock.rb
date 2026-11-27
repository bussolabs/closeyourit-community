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
      # Open production: started and not stopped, or stopped on that phase (a failed release reopens the phase
      # before the stop is written, so the stop itself must hold the lane).
      # CYRA-1371 — a machine stop holds the lane for this long, then the next release goes: it is cut from main
      # and carries the stopped work too. A release a person holds keeps it; a wait for the go-ahead never does.
      MACHINE_STOP_HOLD = 1.hour
      PERSON_HOLD_KIND = "held_by_person"
      NEVER_HOLDS_KIND = "production_approval"

      def self.sql(now: Time.current)
        since = ActiveRecord::Base.connection.quote((now - MACHINE_STOP_HOLD).utc.to_fs(:db))
        <<~SQL.squish
          agents_workflows.cancelled_at IS NULL
          AND agents_workflows.completed_at IS NULL
          AND (
            (agents_workflows.closer_production_started_at IS NOT NULL AND agents_workflows.blocked_at IS NULL)
            OR (agents_workflows.blocked_at IS NOT NULL AND agents_workflows.blocked_phase = 'closer_production'
                AND (agents_workflows.blocked_kind = '#{PERSON_HOLD_KIND}'
                     OR (agents_workflows.blocked_kind IS DISTINCT FROM '#{NEVER_HOLDS_KIND}'
                         AND agents_workflows.blocked_at > #{since})))
          )
        SQL
      end

      # Le lavorazioni che trattengono la fila su questo repository, escluso il workflow dato.
      def self.holders(project:, except: nil)
        scope = Agents::Workflow
                .joins(ticket: :project)
                .where(projects: { id: project.id })
                .where(sql)
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

        workflow.blocked_at? ? stop_holds?(workflow) : workflow.closer_production_started_at?
      end

      def self.stop_holds?(workflow, now: Time.current)
        return false unless workflow.blocked_phase == "closer_production"
        return true if workflow.blocked_kind == PERSON_HOLD_KIND

        workflow.blocked_kind != NEVER_HOLDS_KIND && workflow.blocked_at > now - MACHINE_STOP_HOLD
      end
    end
  end
end
