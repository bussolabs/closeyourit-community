# frozen_string_literal: true

module Servers
  module Actions
    # CYRA-809 — CHI CHIUDE UN'AZIONE RIMASTA A METÀ, E CON QUALE ESITO.
    #
    # Il problema: un'azione presa in carico dall'agent e mai conclusa restava `running` per sempre.
    # Claim riportava in coda solo le running ancora DENTRO la loro finestra di autorizzazione e
    # scadeva solo le queued: la running con lease e autorizzazione entrambe scadute non la toccava
    # nessuno. Occupava così l'unico posto attivo per host (indice parziale su queued|running), e la
    # pagina non poteva annullarla — l'annullamento vale solo per le azioni ancora in attesa. Da lì in
    # poi su quella macchina non partiva più niente, per sempre, senza un rimedio da nessuna parte.
    #
    # CHI: due strade, e servono entrambe.
    #   1. L'AGENT AL RITORNO — Claim chiama questo servizio sul proprio host prima di consegnare.
    #      È la strada che l'utente vede: la macchina si rifà viva e il posto si libera subito.
    #   2. IL GIRO PERIODICO — Servers::ReconcileActionsJob, ogni cinque minuti su tutta la flotta.
    #      È la rete, e non è ridondante: la strada 1 presuppone un ritorno, e la macchina può non
    #      tornare MAI (spenta, dismessa, credenziale revocata). Senza il giro, quel posto resta
    #      occupato finché qualcuno non tocca il database a mano.
    #
    # CON QUALE ESITO: `interrupted` per ciò che era partito, `expired` per ciò che non era mai
    # partito. QUESTO servizio non rimette mai un'azione in coda: ripetere da soli un riavvio o
    # un'installazione di aggiornamenti che forse è già andata a segno è peggio del blocco che si sta
    # togliendo. Il recupero con riconsegna esiste ancora, ma è un'altra cosa e vive in Claim: vale
    # solo DENTRO la finestra di autorizzazione, dove l'azione può ancora essere consegnata
    # legittimamente. Qui si è oltre quella finestra, e lì non si ripete niente. E mai `failed`:
    # nessuno ha visto fallire niente. `interrupted` resta recuperabile — l'esito che arriva tardi lo
    # scrive Actions::Complete, e la riga smette di essere un punto interrogativo.
    #
    # Non è un giudizio definitivo sulla MACCHINA: qui si chiude una riga, non si dichiara nulla sul
    # comando, che può benissimo essere stato eseguito. È esattamente ciò che dice il testo in pagina.
    class Reconcile < ApplicationService
      def initialize(host: nil, now: Time.current, after: Servers::Constants::ACTION_ORPHAN_AFTER_SECONDS)
        @host = host
        @now = now
        @after = after
      end

      def call
        expired_count, expired_hosts = expire_never_started
        interrupted_count, interrupted_hosts = interrupt_orphans
        # Fuori da qualunque transazione, come gli altri broadcast del dominio: chi ha lanciato
        # l'azione sta guardando la pagina e deve smettere di leggere "in corso" da solo.
        broadcast(expired_hosts | interrupted_hosts)
        Result.ok(expired_count + interrupted_count)
      end

      private

      def scope = @host ? @host.actions : Servers::Action.all

      # Mai prese in carico e ormai fuori tempo massimo. Stava dentro Claim, che però la applicava al
      # solo host che si stava presentando: una macchina che non si presenta più lasciava la propria
      # azione in attesa a occupare il posto tanto quanto una running orfana.
      def expire_never_started
        conclude(scope.status_queued.where(expires_at: ..@now), :expired)
      end

      def interrupt_orphans
        conclude(scope.orphaned(@now, after: @after), :interrupted, lease_expires_at: nil)
      end

      # Gli host si raccolgono PRIMA della scrittura: dopo, la riga non risponde più alla condizione
      # che la selezionava. Un host di troppo nella lista costa un aggiornamento di pagina, non un
      # errore — mentre uno mancante lascerebbe scritto "in corso" su un'azione già chiusa.
      #
      # Una scrittura sola, senza lock per riga: la condizione vive nella WHERE, quindi l'azione che
      # si conclude fra la lettura e la scrittura semplicemente non viene presa. Due giri in parallelo
      # — l'agent che si presenta mentre il giro periodico passa — non si fanno male a vicenda.
      def conclude(relation, status, **attributes)
        host_ids = relation.distinct.pluck(:host_id)
        return [ 0, [] ] if host_ids.empty?

        count = relation.update_all(status: Servers::Action.statuses.fetch(status.to_s),
                                    finished_at: @now, updated_at: @now, **attributes)
        [ count, host_ids ]
      end

      def broadcast(host_ids)
        return if host_ids.empty?

        Servers::Host.where(id: host_ids).find_each { |host| Servers::Broadcast.refresh(host) }
      end
    end
  end
end
