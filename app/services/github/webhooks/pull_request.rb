# frozen_string_literal: true

module Github
  module Webhooks
    # Evento `pull_request` (opened/closed/reopened/edited/...): upsert della PR agganciata al ticket
    # (prefisso KEY-N in head_ref/titolo/body) e registrazione degli eventi ticket sulle TRANSIZIONI di
    # stato (idempotente: la stessa consegna ripetuta non raddoppia gli eventi). PR merged + repo
    # `autoclose_on_merge` → porta il ticket in stato done.
    class PullRequest < Base
      # Il numero della proposta finisce in una colonna intera da 4 byte: oltre, il salvataggio
      # solleva RangeError invece di scrivere (CYRA-720).
      NUMBER_RANGE = (1..2_147_483_647)

      def call
        repo = repository
        return Result.ok(nil) if repo.nil? || !repo.sync_enabled?

        pr = object_at(@payload, "pull_request")
        number = value_at(pr, "number")
        # Il numero è la chiave della proposta dentro il repo: se non è un numero scrivibile la
        # consegna non è utilizzabile e si lascia cadere. Senza questa guardia un payload malformato
        # arrivava fino al salvataggio e sollevava lì (CYRA-720).
        return Result.ok(nil) unless number.to_s.match?(/\A\d+\z/) && NUMBER_RANGE.cover?(number.to_i)

        ticket = ticket_from(value_at(pr, "head", "ref"), value_at(pr, "title"), value_at(pr, "body"))
        record, previous_state = upsert_pull(repo, pr, number, ticket)
        return Result.ok(nil) if record.nil?

        register_events(ticket, record, previous_state, number) if ticket
        autoclose(repo, ticket, record, previous_state) if ticket

        Result.ok(record)
      end

      private

      # Idempotente sulla race di creazione: GitHub consegna gli webhook at-least-once, quindi due
      # consegne concorrenti della stessa PR provano entrambe a scrivere la stessa riga. La seconda
      # fallisce in uno di due modi, secondo il timing: `RecordInvalid` (la validazione di unicità
      # vede la riga gemella già committata) o `RecordNotUnique` (la validazione passa ma l'INSERT
      # colpisce l'indice unico repository_id+number — è quel che si è visto in produzione). In
      # entrambi i casi la riga già scritta viene recuperata e aggiornata invece di propagare
      # l'errore (CYRA-199), come Errors::Ingest::Record fa per event_id. Al retry previous_state è
      # lo stato scritto dall'altra consegna, così register_events non raddoppia l'evento di
      # transizione. Ogni altra validazione fallita resta un errore vero e viene ri-sollevata.
      def upsert_pull(repo, pr, number, ticket)
        record = repo.pull_requests.find_or_initialize_by(number: number)
        previous_state = record.new_record? ? nil : record.state
        assign_pull_attributes(record, pr, number, ticket)
        # L'indirizzo della proposta è obbligatorio sulla riga: se la consegna non lo porta e non c'è
        # già scritto non c'è niente da salvare. Si lascia cadere invece di far fallire la lavorazione
        # su una validazione (CYRA-720) — le altre validazioni restano errori veri, vedi sotto.
        return nil if record.html_url.blank?

        record.save!
        [ record, previous_state ]
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
        raise if e.is_a?(ActiveRecord::RecordInvalid) && !e.record.errors.of_kind?(:number, :taken)

        record = repo.pull_requests.find_by!(number: number)
        previous_state = record.state
        assign_pull_attributes(record, pr, number, ticket)
        record.save!
        [ record, previous_state ]
      end

      # I metadati descrittivi non si azzerano: una consegna che non li porta (o li porta nella forma
      # sbagliata, che dopo CYRA-720 vale come non portati) lascia in piedi quel che una consegna sana
      # aveva già scritto, invece di cancellarlo. Stessa scelta già in uso per titolo, indirizzo e
      # collegamento al ticket. Fuori dalla regola resta merged_at: lì il valore vuoto è informativo
      # (proposta non unita) e deve poter tornare indietro.
      def assign_pull_attributes(record, pr, number, ticket)
        record.assign_attributes(
          title: value_at(pr, "title").presence || record.title.presence || "##{number}",
          state: state_for(pr),
          head_ref: value_at(pr, "head", "ref").presence || record.head_ref,
          base_ref: value_at(pr, "base", "ref").presence || record.base_ref,
          html_url: value_at(pr, "html_url").presence || record.html_url,
          github_id: value_at(pr, "id").presence || record.github_id,
          author_login: value_at(pr, "user", "login").presence || record.author_login,
          merged_at: value_at(pr, "merged_at")
        )
        assign_head_sha(record, pr)
        record.ticket = ticket if ticket # non azzera un link già presente se il webhook non lo porta
      end

      # CYRA-600 — gli webhook arrivano at-least-once e FUORI ORDINE: una consegna vecchia che
      # sovrascrive una nuova farebbe tornare indietro il codice annotato, e chi guarda vedrebbe un
      # commit che non è più la testa. Quindi si scrive solo se la consegna non è anteriore a quella
      # già registrata.
      #
      # Un payload senza orario non si può ordinare: in quel caso si scrive solo a colonna vuota,
      # mai sopra un valore che qualcuno ha già messo con un orologio in mano.
      #
      # La guardia vale su questi due campi soltanto. Stato, eventi e chiusura automatica restano
      # come sono: lì una consegna fuori ordine ha già le sue difese, e allargare la regola
      # cambierebbe comportamenti che nessuno ha chiesto di cambiare.
      def assign_head_sha(record, pr)
        delivery_time = parse_time(value_at(pr, "updated_at"))
        return if delivery_time.nil? && record.head_sha.present?
        return if delivery_time && record.github_updated_at && delivery_time < record.github_updated_at

        sha = value_at(pr, "head", "sha")
        record.head_sha = sha if sha.present?
        record.github_updated_at = delivery_time if delivery_time
      end

      # Un orario illeggibile (o impossibile, tipo un mese 13) vale come consegna senza orario: non si
      # può ordinare, ma non deve far fallire tutto il resto della consegna.
      def parse_time(value)
        value.present? ? Time.zone.parse(value.to_s) : nil
      rescue ArgumentError
        nil
      end

      def state_for(pr)
        return :merged if value_at(pr, "merged") == true
        return :closed if value_at(pr, "state") == "closed" || value_at(@payload, "action") == "closed"

        :open
      end

      # Eventi sulle transizioni: aperto (record nuovo) / mergiato / chiuso-non-mergiato. Un solo evento
      # per transizione → niente doppioni sulle consegne ripetute o sull'apertura fatta da CloseYourIt.
      def register_events(ticket, record, previous_state, number)
        if record.state_merged? && previous_state != "merged"
          record_activity(ticket, "pull_request_merged", number:)
        elsif record.state_closed? && previous_state != "closed"
          record_activity(ticket, "pull_request_closed", number:)
        elsif value_at(@payload, "action") == "opened" && previous_state.nil?
          record_activity(ticket, "pull_request_opened", number:)
        end
      end

      def autoclose(repo, ticket, record, previous_state)
        return unless repo.autoclose_on_merge? && record.state_merged? && previous_state != "merged"

        status = repo.project.organization.ticket_statuses.active.where(category: :done).ordered.first
        # CYRA-613 — anche questo ramo era muto: il codice veniva unito, il ticket restava aperto, e
        # da fuori era identico a una chiusura riuscita. Se l'organizzazione non ha uno stato «Fatto»
        # attivo non c'e' dove portare il ticket, e va detto invece che taciuto.
        if status.nil?
          record_activity(ticket, "pull_request_autoclose_declined", number: record.number,
                                  reason: "no_done_status")
          return
        end

        # CYRA-609 — unire il codice non chiude piu' il ticket da se'. Il tentativo pero' non sparisce:
        # sulla scheda resta scritto che c'e' stato e che a decidere e' la lavorazione. Prima l'esito
        # veniva ignorato, quindi una chiusura rifiutata era indistinguibile da una riuscita.
        result = Ticketing::ChangeStatus.call(organization: repo.project.organization, ticket:,
                                              status_id: status.id, channel: :webhook)
        return if result.ok?

        Rails.logger.info("[github.autoclose] rifiutata: #{result.error.code} ticket=#{ticket.code}")
        record_activity(ticket, "pull_request_autoclose_declined", number: record.number,
                                reason: result.error.code)
      end
    end
  end
end
