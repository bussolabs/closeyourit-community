# frozen_string_literal: true

module Home
  # Tipi condivisi da chi COMPONE il feed della home e da chi compone la pila delle approvazioni
  # (CYRA-262). Stanno qui, e non dentro Home::ActionInbox, perché due lettori della stessa forma
  # sono l'inizio di due forme diverse: la pagina Approvazioni rende gli stessi Item della home,
  # con gli stessi Action già gated.
  module Feed
    # Azione veloce di una riga. `params` = campi nascosti che identificano il record al controller
    # (es. { ticket_id: … }). `needs_reason` → il pulsante chiede un motivo obbligatorio invece di
    # essere un submit secco.
    Action = Data.define(:key, :path, :method, :variant, :needs_reason, :params)

    # Stato del ticket a cui la riga si riferisce (CYRA-316): label + color già pronti per
    # Ui::BadgeComponent — il `color` dello status org-custom è un nome Tailwind, la stessa chiave che
    # il badge accetta. Valorizzato solo per le famiglie con un ticket (review/clarification/agent_plan);
    # nil per secret_change e per il feed della home che non lo legge.
    Badge = Data.define(:label, :color)

    # Item normalizzato di una riga. `tone` = simbolo semantico (:amber/:indigo/…), che oggi
    # nessuna vista legge più (CYRA-658: se ne serviva il cerchio-icona del feed). `dom_id` = target Turbo.
    # `key` = "famiglia:uuid", l'identificativo stabile con cui la pagina Approvazioni seleziona la
    # card nell'URL (nil per le famiglie senza pagina di decisione dedicata). `waiting_since`
    # valorizzato = ho già chiesto precisazioni e sto aspettando risposta: la riga resta in pila ma
    # scende in fondo. `sort_at` = ancora d'età. `bulk_approvable` (CYRA-284) → la riga può entrare in
    # una selezione multipla da accettare in blocco: è il SUGGERIMENTO per la UI (mostrare o no la
    # casella), NON il gate — quello resta Home::Approvals::Detail::Card#bulk_approvable?.
    # `state` (CYRA-290) = lo stato FINE della riga, più stretto di `kind`: per gli automi è la fase
    # (piano da approvare / lavoro consegnato / lavorazione ferma), non la famiglia. È l'asse su cui
    # la pagina Approvazioni filtra e conta; il vocabolario è Home::Approvals::Queue::STATES. Il feed
    # della home non lo legge, quindi resta nil lì. `ticket_status` (CYRA-316) = lo stato del ticket a
    # cui la riga si riferisce (Badge label/color), reso accanto alla sigla del progetto; nil se la riga
    # non ha un ticket.
    # `project` (CYRA-319) = il progetto della riga come sigla + nome esteso: la sigla da sola è
    # l'unico raggruppamento visibile della coda, e senza il nome per esteso non dice niente a chi
    # quei progetti non li ha creati. Nil per le righe che un progetto non ce l'hanno.
    ProjectRef = Data.define(:key, :name)

    # `agent` (CYRA-448) = la macchina che ha prodotto il lavoro in attesa di decisione. Fra gli
    # agenti che producono e le decisioni da smaltire non c'era nessun filo: dalla coda non si sapeva
    # chi avesse generato cosa, e dalla scheda di un agente non si arrivava a ciò che ha lasciato in
    # sospeso. Nil per le righe storiche senza host: lì la coda dice "agente sconosciuto" invece di
    # nascondere la card.
    AgentRef = Data.define(:id, :name)

    # `code` (CYRA-303) = codice del ticket a cui la riga si riferisce (es. CYRA-12), nil per le righe
    # che un ticket non ce l'hanno (le richieste sui secret). La coda delle approvazioni lo mette in
    # testa alla riga insieme al titolo del ticket: sono le sole due informazioni che distinguono una
    # riga dall'altra, mentre il tipo — identico su decine di righe — scende a etichetta.
    # CYRA-658 — via `reply`, `vote` e `preview`: erano i tre campi che il feed a quattro elenchi
    # leggeva per la casella di risposta, il pulsante di voto e i badge dell'analisi. Il feed non
    # c'è più e nessuno li popolava più: tenerli avrebbe lasciato tre campi sempre nil che il
    # prossimo lettore avrebbe provato a riempire.
    Item = Data.define(:kind, :icon, :tone, :title, :subtitle, :meta, :url, :sort_at, :dom_id, :key,
                       :waiting_since, :actions, :bulk_approvable, :state, :ticket_status,
                       :code, :project, :agent, :freeze_warning, :no_report, :plan_version)

    # `freeze_warning` (CYRA-610) = l'avviso, in chiaro, quando approvare quel piano NON riuscirebbe a
    # fissare dove il lavoro può nascere e come si prova che è finito. Vive sull'item e non solo nella
    # scheda di dettaglio perché da questo elenco si approva in blocco senza aprire niente: un avviso
    # che sta solo nel dettaglio lascerebbe alla cieca proprio il gesto che decide dieci piani insieme.
    # Nil ovunque non ci sia un piano da approvare.

    # Sezione (famiglia): `items` già tagliati al limite, `total` = conteggio pieno.
    Section = Data.define(:key, :items, :total, :more_url) do
      def any? = total.positive?
      def more_count = [ total - items.size, 0 ].max
    end

    # Costruttore con i default: chi compone un Item passa solo ciò che ha davvero.
    def self.item(actions: [], key: nil, waiting_since: nil,
                  bulk_approvable: false, state: nil, ticket_status: nil, code: nil,
                  project: nil, agent: nil, freeze_warning: nil, no_report: false, plan_version: nil, **attributes)
      Item.new(actions: actions, key: key, waiting_since: waiting_since,
               bulk_approvable: bulk_approvable, state: state, ticket_status: ticket_status,
               code: code, project: project, agent: agent,
               freeze_warning: freeze_warning, no_report: no_report, plan_version: plan_version, **attributes)
    end
  end
end
