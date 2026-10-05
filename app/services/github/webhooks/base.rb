# frozen_string_literal: true

module Github
  module Webhooks
    # Base degli handler webhook: risolve il repo agganciato dal payload e incapsula il binding di un
    # tag alla release live (tramite Github::Releases::Reconcile, che è idempotente).
    #
    # Il payload è JSON che arriva da fuori: la firma HMAC dice DA CHI viene la consegna, non com'è
    # fatta dentro. Un campo che il contratto vuole oggetto può arrivare stringa, lista o assente, e
    # `dig` su una stringa solleva TypeError — cioè un 500 al posto di un no-op (CYRA-720). Perciò il
    # payload si legge SEMPRE con object_at/value_at: quel che non ha la forma attesa vale come assente.
    class Base < ApplicationService
      def initialize(payload:)
        @payload = payload.is_a?(Hash) ? payload : {}
      end

      private

      # Sotto-oggetto del payload: sempre un Hash, vuoto se il percorso manca o non porta a un oggetto.
      def object_at(source, *keys)
        found = keys.reduce(source) { |current, key| current.is_a?(Hash) ? current[key] : nil }
        found.is_a?(Hash) ? found : {}
      end

      # Valore scalare in fondo a un percorso di oggetti. nil se un livello intermedio non è un oggetto
      # o se in fondo c'è a sua volta una struttura (un id che arriva come lista non è un id).
      def value_at(source, *keys)
        value = object_at(source, *keys[0..-2])[keys.last]
        value.is_a?(Hash) || value.is_a?(Array) ? nil : value
      end

      # Installazione GitHub App del payload. nil se il payload non la porta o non esiste nel DB.
      def installation
        @installation ||= Github::Installation.find_by(installation_id: value_at(@payload, "installation", "id"))
      end

      # Repo agganciato corrispondente al repository del payload, cercato SOTTO l'installazione del
      # payload (repo_id non è unico globalmente, solo per installazione). nil se l'installazione manca
      # o il repo non è agganciato a nessun progetto in quella installazione.
      #
      # CYRA-722 — e nil anche quando l'organizzazione dell'installazione è sospesa: le consegne di
      # GitHub continuano ad arrivare (l'app resta installata) ma non devono più muovere niente. Il
      # filtro sta qui, non nei singoli handler, perché è il punto da cui passano tutti quelli che
      # toccano dati: chi non trova il repo è già scritto per non fare nulla. L'handler
      # `Installation` non passa di qui apposta — disinstallare deve restare possibile.
      def repository
        return @repository if defined?(@repository)

        @repository =
          if installation&.organization&.suspended?
            nil
          else
            installation&.repositories&.find_by(repo_id: value_at(@payload, "repository", "id"))
          end
      end

      # Estrae il codice ticket (KEY-N, case-insensitive) dalle stringhe date (nome branch, titolo/body
      # PR) e risolve il ticket nel progetto del repo. nil se nessun match o ticket inesistente.
      def ticket_from(*texts)
        repo = repository
        return nil if repo.nil?

        pattern = /#{Regexp.escape(repo.project.key)}-(\d+)/i
        texts.compact.each do |text|
          next unless (match = pattern.match(text.to_s))

          ticket = repo.project.tickets.find_by(number: match[1].to_i)
          return ticket if ticket
        end
        nil
      end

      # L'evento arriva da GitHub, non da un account dell'organizzazione: si dichiara per nome
      # (CYRA-406), invece di restare senza autore e comparire come una persona ignota.
      def record_activity(ticket, action, **data)
        Ticketing::RecordActivity.call(ticket:, action:, data:,
                                       actor_name: I18n.t("member.tickets.activity.system.github"))
      end

      # Lega il tag alla release live nel suo environment target (stabile→production, pre-release→staging
      # dalle regole del repo). No-op se il repo non è agganciato/sync spento o il lato non è mappato.
      def bind_tag(tag, git_tag_url: nil)
        repo = repository
        return Result.ok(nil) if repo.nil? || !repo.sync_enabled?

        target = repo.target_environment_code(stable: Github::Version.stable?(tag))
        return Result.ok(nil) if target.blank?

        Github::Releases::Reconcile.call(
          project: repo.project, version: tag, environment: target, git_tag_url:
        )
      end
    end
  end
end
